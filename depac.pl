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
my $wpad_file;
newdaemon(
    progname                => 'depac',
    pidfile                 => "$ENV{HOME}/.depac.pid",
    options                 => {
        'bindhost=s'        => \$bind_host,
        'bindport=i'        => \$bind_port,
        'wpadfile=s'        => \$wpad_file,
    },
);

sub gd_flags_more {
    return (
        '--bindhost ADDR'   => 'Accept connection at this host address (default: 127.0.0.1)',
        '--bindport PORT'   => 'Accept connection at this port (default: random port)',
        '--wpadfile URL'    => 'Manually specify the URL of the "wpad.dat" file (default: DNS autodiscovery)',
    );
}

# shamelessly stolen from https://metacpan.org/source/MACKENNA/HTTP-ProxyPAC-0.31/lib/HTTP/ProxyPAC/Functions.pm
sub _validIP {
    return ($_[0] =~ m{^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$}x
        && $1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255);
}

sub _process_wpad {
    my %memoize;
    my $je = JE->new;

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
            $_[0] = dnsResolve($_[0]) unless _validIP($_[0]);
            (!$_[0] || !_validIP($_[1]) || !_validIP($_[2]))
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

    my $cv = AnyEvent->condvar;
    my $t = AnyEvent->timer(after => 1.0, cb => sub { $cv->send });
    if ($wpad_file) {
        AE::log info => 'fetching %s', $wpad_file;
        http_get $wpad_file => sub {
            my ($body, $hdr) = @_;
            if (($hdr->{Status} != 200) || !length($body)) {
                AE::log fatal => "couldn't GET %s", $wpad_file;
            } else {
                $cv->send($body);
            }
        };
    } else {
        my $hostdomain  = Net::Domain::hostdomain;
        AE::log info => 'searching domain %s', $hostdomain;
        my @hostdomain = split m{\.}x, $hostdomain;
        while ($#hostdomain) {
            my $wpad = URI->new('http://wpad.' . join('.', @hostdomain));
            $wpad->path('/wpad.dat');
            AE::log info => 'fetching %s', $wpad;
            http_get $wpad->canonical->as_string => sub {
                my ($body, $hdr) = @_;
                if (($hdr->{Status} != 200) || !length($body)) {
                    AE::log info => "couldn't GET %s", $wpad;
                } else {
                    $cv->send($body);
                }
            };
            shift @hostdomain;
        }
    }
    my $body = $cv->recv;
    AE::log fatal => "COULDN'T FIND WPAD" unless $body;
    $je->eval($body);

    return $je;
}

sub _ping_pid {
    my ($proxy) = @_;
    my $cv = AnyEvent->condvar;
    my $url = URI->new($proxy);
    $url->path('/pid');
    AE::log info => 'pinging %s', $url;
    http_get $url->canonical->as_string,
        proxy   => undef,
        timeout => 1.0,
        sub {
            my ($body, $hdr) = @_;
            if (($hdr->{Status} != 200) || !length($body)) {
                AE::log info => "couldn't GET %s", $url;
                $cv->send(0);
            } else {
                chomp $body;
                $cv->send($body);
            }
        };
    return $cv->recv;
}

sub gd_run {
    my ($self) = @_;
    my %pool;
    my $w;
    $w = AnyEvent->signal(signal => 'INT', cb => sub {
        AE::log info => 'Shutting down...';
        %pool = ();
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
            if ($line =~ m{^CONNECT\s+([\w\.\-]+):([0-9]+)\s+(HTTP/1\.[01])$}ix) {
                ($verb, $peer_host, $peer_port, $proto) = ('CONNECT', $1, $2, $3);
            } elsif ($line =~ m{^(DELETE|GET|HEAD|OPTIONS|POST|PUT|TRACE)\s+(https?://.+)\s+(HTTP/1\.[01])$}ix) {
                $url = URI->new($2);
                ($verb, $peer_host, $peer_port, $proto) = (uc($1), $url->host, $url->port, $3);
            } elsif ($line =~ m{^GET\s+/pid\s+HTTP/1\.[01]$}ix) {
                AE::log info => 'status request from %s:%d', $host, $port;
                $_h->push_write(
                    'HTTP/1.0 200 OK' . $eol .
                    'Cache-Control: no-cache' . $eol .
                    'Connection: close' . $eol .
                    'Content-Type: text/plain' . $eol . $eol .
                    $$ . $eol
                );
                $_h->push_shutdown;
                return;
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
            my $proxy = $self->{je}->{FindProxyForURL}->(
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
    };
    AnyEvent->condvar->wait;
    return;
}

sub gd_preconfig {
    my ($self) = @_;
    if ($self->{do} =~ /^(start|debug)$/x) {
        my $envfile = $self->{gd_pidfile};
        $envfile =~ s/\.pid$//ix;
        $envfile .= '.env';
        if (-e $envfile) {
            AE::log debug => 'checking previous environment at %s', $envfile;
            open(my $fh, '<', $envfile)
                || AE::log fatal => "can't read from %s: %s", $envfile, $!;
            my $proxy;
            my @env;
            while (my $line = <$fh>) {
                $proxy = $1 if $line =~ m{^export\s+https?_proxy="(http://[\w\.\-]+:[0-9]+)"}isx;
                push @env => $line;
            }
            close $fh;
            AE::log fatal => "couldn't find running process address in %s", $envfile
                unless $proxy;
            if (my $pid = _ping_pid($proxy)) {
                AE::log info => 'running proxy has PID %d', $pid;
                print for @env;
                exit;
            }
        }

        $self->{je} = _process_wpad();
        unless ($bind_port) {
            $bind_port = IO::Socket::INET->new(
                LocalAddr       => $bind_host,
                Proto           => 'tcp',
            )->sockport;
        }
        my $proxy = URI->new('http://' . $bind_host);
        $proxy->port($bind_port);

        AE::log info => 'writing environment proxy settings to %s', $envfile;
        my @env;
        push @env => qq(export $_="$proxy"\n) for map { $_ => uc } qw(http_proxy https_proxy);
        push @env => qq(export $_="localhost,127.0.0.1"\n) for map { $_ => uc } qw(no_proxy);
        print for @env;
        open(my $fh, '>', $envfile)
            || AE::log fatal => "can't write to %s: %s", $envfile, $!;
        print $fh $_ for @env;
        close $fh;
    }
    return ();
}

sub gd_kill {
    my ($self, $pid) = @_;
    kill INT => $pid;
    print qq(unset $_\n) for map { $_ => uc } qw(http_proxy https_proxy no_proxy);
    return;
}
