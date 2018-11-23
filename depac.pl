#!/usr/bin/env perl
use 5.010;
use strict;
use warnings qw(all);

use AnyEvent::HTTP;
use AnyEvent::Socket;
use Daemon::Generic;
use IO::Socket;
use JE;
use Net::Domain;
use URI;

my $bind_host   = '127.0.0.1';
my $bind_port   = 0;
my $hostdomain  = Net::Domain::hostdomain;
my $exports     = 1;

newdaemon(
    progname                => 'depac',
    pidfile                 => "$ENV{HOME}/.depac.pid",
    options                 => {
        'bind_host=s'       => \$bind_host,
        'bind_port=i'       => \$bind_port,
        'hostdomain=s'      => \$hostdomain,
        'exports!'          => \$exports,
    },
);

sub gd_flags_more {
    +(
        '--bind_host ADDR'  => 'Accept connection at this host address (default: 127.0.0.1)',
        '--bind_port PORT'  => 'Accept connection at this port (default: random port)',
        '--hostdomain HOST' => 'Something like "pc.department.branch.example.com", should be discovered automatically',
        '--noexports'       => 'Do not print the export/unset statements',
    );
}

sub gd_run {
    my %memoize;
    my $je = JE->new;

    # shamelessly stolen from https://metacpan.org/source/MACKENNA/HTTP-ProxyPAC-0.31/lib/HTTP/ProxyPAC/Functions.pm
    sub validIP {
        $_[0] =~ m{^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$}x
            && $1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255;
    }
    $je->new_function(dnsDomainIs => sub {
        $memoize{ join('|', __LINE__, @_) } //= do {
            my $host_len = length $_[0];
            my $domain_len = length $_[1];
            my $d = length($_[0]) - length($_[1]);
            ($d >= 0) && (substr($_[0], $d) eq $_[1]);
        };
    });
    $je->new_function(dnsDomainLevels => sub {
        $memoize{ join('|', __LINE__, @_) } //= do {
            $#{[ split m{\.}x, $_[0] ]};
        };
    });
    $je->new_function(dnsResolve => sub {
        $memoize{ join('|', __LINE__, @_) } //= do {
            my $addr = inet_aton($_[0]);
            $addr ? inet_ntoa($addr) : ();
        };
    });
    $je->new_function(isInNet => sub {
        $memoize{ join('|', __LINE__, @_) } //= do {
            $_[0] = dnsResolve($_[0]) unless validIP($_[0]);
            (!$_[0] || !validIP($_[1]) || !validIP($_[2]))
                ? () : (inet_aton($_[0]) & inet_aton($_[2])) eq (inet_aton($_[1]) & inet_aton($_[2]));
        };
    });
    $je->new_function(isPlainHostName => sub {
        $memoize{ join('|', __LINE__, @_) } //= do {
            index($_[0], '.') == -1;
        };
    });
    $je->new_function(isResolvable => sub {
        $memoize{ join('|', __LINE__, @_) } //= do {
            defined(gethostbyname($_[0]));
        };
    });
    $je->new_function(localHostOrDomainIs => sub {
        $memoize{ join('|', __LINE__, @_) } //= do {
            ($_[0] eq $_[1]) || rindex($_[1], $_[0] . '.') == 0;
        };
    });
    $je->new_function(myIpAddress => sub {
        $memoize{myIpAddress} //= do {
            my $addr = inet_aton(Net::Domain::hostname);
            $addr ? inet_ntoa($addr) : '127.0.0.1';
        };
    });
    $je->new_function(shExpMatch => sub {
        $memoize{ join('|', __LINE__, @_) } //= do {
            $_[1] =~ s{ \* }{.*?}gx;
            !!($_[0] =~ m{$_[1]}ix);
        };
    });

    AE::log info => 'searching domain %s', $hostdomain;
    my @hostdomain = split m{\.}x, $hostdomain;
    my $cv = AnyEvent->condvar;
    my $t = AnyEvent->timer(after => 1.0, cb => sub { $cv->send });
    while ($#hostdomain) {
        my $wpad = URI->new('http://wpad.' . join('.', @hostdomain));
        $wpad->path('/wpad.dat');
        AE::log info => 'fetching %s', $wpad;
        http_get $wpad->canonical->as_string => sub {
            my ($body, $hdr) = @_;
            if (($hdr->{Status} != 200) || !length($body)) {
                AE::log info => "couldn't GET %s", $wpad;
            } else {
                AE::log info => 'evaluating %s', $wpad;
                $cv->send($body);
            }
        };
        shift @hostdomain;
    }
    my $body = $cv->recv;
    AE::log fatal => "COULDN'T FIND WPAD" unless $body;
    $je->eval($body);

    my %pool;
    my $w;
    $w = AnyEvent->signal(signal => 'INT', cb => sub {
        AE::log info => 'Shutting down...';
        %pool = ();
        undef $t;
        undef $w;
        exit;
    });
    tcp_server $bind_host, $bind_port, sub {
        my ($fh, $host, $port) = @_;
        AE::log info => 'new connection from %s:%d (%d in pool)', $host, $port, scalar keys %pool;
        my $h = AnyEvent::Handle->new(
            fh          => $fh,
            on_eof    => sub {
                $_[0]->destroy;
                delete $pool{ fileno($fh) };
            },
            on_error    => sub {
                $_[0]->destroy;
                delete $pool{ fileno($fh) };
            },
        );
        $pool{ fileno($fh) } = $h;
        $h->push_read(line => sub {
            my ($_h, $line, $eol) = @_;
            AE::log debug => '[from %s:%d] %s', $host, $port, $line;
            my $url;
            my ($verb, $peer_host, $peer_port, $proto);
            if ($line =~ m{^(DELETE|GET|HEAD|OPTIONS|POST|PUT|TRACE)\s+(https?://.+)\s+(HTTP/1\.[01])$}ix) {
                $url = URI->new($2);
                ($verb, $peer_host, $peer_port, $proto) = (uc($1), $url->host, $url->port, $3);
            } elsif ($line =~ m{^CONNECT\s+([\w\.\-]+):([0-9]+)\s+(HTTP/1\.[01])$}ix) {
                ($verb, $peer_host, $peer_port, $proto) = ('CONNECT', $1, $2, $3);
            } else {
                AE::log error => 'bad request from %s:%d', $host, $port;
                $_h->push_write(
                    'HTTP/1.0 400 Bad request' . $eol .
                    'Cache-Control: no-cache' . $eol .
                    'Connection: close' . $eol .
                    'Content-Type: text/html' . $eol . $eol .
                    '<html><body><h1>400 Bad request</h1></body></html>'
                );
                $_h->push_shutdown;
                return;
            }

            # my $proxy = 'DIRECT';
            my $proxy = $je->{FindProxyForURL}->(
                ($verb eq 'CONNECT' ? 'https' : 'http') . '://' . $peer_host, # HACK!
                $peer_host,
            );
            AE::log debug => 'WPAD says we should use %s', $proxy;

            my $peer_h;
            if ($proxy =~ m{^DIRECT\b}ix) {
                AE::log debug => 'connecting directly to %s:%d', $peer_host, $peer_port;
                $peer_h = AnyEvent::Handle->new(
                    connect     => [$peer_host => $peer_port],
                    on_eof      => sub { $_[0]->destroy },
                    on_error    => sub { $_[0]->destroy },
                    on_connect  => sub {
                        if ($verb eq 'CONNECT') {
                            AE::log debug => '[to %s:%d]', $peer_host, $peer_port;
                            $_h->push_read(regex => qr{(?:\015?\012){2}}x, sub {
                                AE::log debug => 'skipping headers on CONNECT';
                                $_h->push_write('HTTP/1.0 200 Connection established' . $eol . $eol);
                            });
                        } else {
                            $line = join ' ', $verb, $url->path_query, $proto;
                            AE::log debug => '[to %s:%d] %s', $peer_host, $peer_port, $line;
                            $peer_h->push_write($line . $eol);
                        }
                        $_h->on_read(sub {
                            AE::log trace => 'send %d bytes to %s:%d', length($_[0]->rbuf), $peer_host, $peer_port;
                            $peer_h->push_write($_[0]->rbuf);
                            $_[0]->rbuf = '';
                        });
                        $peer_h->on_read(sub {
                            AE::log trace => 'recv %d bytes from %s:%d', length($_[0]->rbuf), $peer_host, $peer_port;
                            $_h->push_write($_[0]->rbuf);
                            $_[0]->rbuf = '';
                        });
                    }
                );
            } else {
                my ($proxy_host, $proxy_port) = ($proxy =~ m{^PROXY\s+([\w\.]+):([0-9]+)}ix);
                AE::log debug => 'connecting to %s:%d via %s:%d', $peer_host, $peer_port, $proxy_host, $proxy_port;
                $peer_h = AnyEvent::Handle->new(
                    connect     => [$proxy_host => $proxy_port],
                    on_eof      => sub { $_[0]->destroy },
                    on_error    => sub { $_[0]->destroy },
                    on_connect  => sub {
                        AE::log debug => '[to %s:%d] %s', $proxy_host, $proxy_port, $line;
                        $peer_h->push_write($line . $eol);
                        $_h->on_read(sub {
                            AE::log trace => 'send %d bytes to %s:%d', length($_[0]->rbuf), $proxy_host, $proxy_port;
                            $peer_h->push_write($_[0]->rbuf);
                            $_[0]->rbuf = '';
                        });
                        $peer_h->on_read(sub {
                            AE::log trace => 'recv %d bytes from %s:%d', length($_[0]->rbuf), $proxy_host, $proxy_port;
                            $_h->push_write($_[0]->rbuf);
                            $_[0]->rbuf = '';
                        });
                    }
                );
            }
        });
    }, sub {
        my ($fh, $this_host, $this_port) = @_;
        AE::log info => 'STARTING THE SERVER AT %s:%d', $this_host, $this_port;
        return unless $exports;
        my $proxy = URI->new('http://' . $this_host);
        $proxy->port($this_port);
        say qq(export $_="$proxy") for map { $_ => uc } qw(http_proxy https_proxy);
        say qq(export $_="localhost,127.0.0.1") for map { $_ => uc } qw(no_proxy);
    };
    AnyEvent->condvar->wait;
}

sub gd_daemonize {
    my ($self) = @_;
    my $pid;
    POSIX::_exit(0) if $pid = fork;
    AE::log fatal => "Couldn't fork: $!" unless defined $pid;
    POSIX::setsid();
}

sub gd_kill {
    my ($self, $pid) = @_;
    kill INT => $pid;
    return unless $exports;
    say qq(unset $_) for map { $_ => uc } qw(http_proxy https_proxy no_proxy);
}
