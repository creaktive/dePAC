#!/usr/bin/env perl
use 5.010001;
use strict;
use warnings qw(all);

use AnyEvent::HTTP;
use AnyEvent::Socket;
use Getopt::Long;
use IO::Socket;
use JE;
use Net::Domain;
use POSIX;

main();

# shamelessly stolen from https://metacpan.org/source/MACKENNA/HTTP-ProxyPAC-0.31/lib/HTTP/ProxyPAC/Functions.pm
sub _validIP {
    return ($_[0] =~ m{^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$}x
        && $1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255);
}

sub _process_wpad {
    my ($wpad_file) = @_;
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
        http_get $wpad_file,
            proxy => undef,
            sub {
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
            my $wpad = 'http://wpad.' . join('.', @hostdomain) . '/wpad.dat';
            AE::log info => 'fetching %s', $wpad;
            http_get $wpad,
                proxy => undef,
                sub {
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
    AE::log fatal => "COULDN'T EVALUATE WPAD" if $@;

    return $je;
}

sub _ping_pid {
    my ($url) = @_;
    $url .= '/pid';
    my $cv = AnyEvent->condvar;
    AE::log info => 'pinging %s', $url;
    http_get $url,
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

sub run {
    my ($bind_host, $bind_port, $je, $cb) = @_;
    my $cv = AnyEvent->condvar;
    my %pool;
    my $w;
    $w = AnyEvent->signal(signal => 'INT', cb => sub {
        AE::log info => 'shutting down...';
        %pool = ();
        undef $w;
        $cv->send;
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
            } elsif ($line =~ m{^(DELETE|GET|HEAD|OPTIONS|POST|PUT|TRACE)\s+(?:https?)://([\w\.\-]+)(?::([0-9]+))?\S*\s+(HTTP/1\.[01])$}ix) {
                ($verb, $peer_host, $peer_port, $proto) = (uc($1), $2, $3, $4);
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
                delete $pool{ fileno($fh) };
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
                delete $pool{ fileno($fh) };
                return;
            }

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
    }, $cb;
    return $cv;
}

sub _daemonize {
    open(\*STDOUT, '>', '/dev/null') || AE::log fatal => "open >/dev/null: $@";
    open(\*STDIN,  '<', '/dev/null') || AE::log fatal => "open </dev/null: $@";
    open(\*STDERR, '>', '/dev/null') || AE::log fatal => "dup stdout > stderr: $@";
    my $pid;
    POSIX::_exit(0) if $pid = fork;
    AE::log fatal => "couldn't fork: $@" unless defined $pid;
    POSIX::setsid();
}

sub _help {
    print q(Usage: depac [options]
    --bind_host ADDR     Accept connection at this host address (default: 127.0.0.1)
    --bind_port PORT     Accept connection at this port (default: random port)
    --wpad_file URL      Manually specify the URL of the "wpad.dat" file (default: DNS autodiscovery)
);
}

sub main {
    my $bind_host = '127.0.0.1';
    my $env_file = $ENV{HOME} . '/.depac.env';
    my $detach = 1;
    my ($bind_port, $wpad_file, $help, $stop);
    GetOptions(
        'bind_host=s'   => \$bind_host,
        'bind_port=i'   => \$bind_port,
        'detach!'       => \$detach,
        'env_file=s'    => \$env_file,
        'help'          => \$help,
        'stop'          => \$stop,
        'wpad_file=s'   => \$wpad_file,
    );
    _help && exit if $help;

    my $proxy;
    if (-e $env_file) {
        AE::log debug => 'checking previous environment at %s', $env_file;
        open(my $fh, '<', $env_file)
            || AE::log fatal => "can't read from %s: %s", $env_file, $@;
        my @env;
        while (my $line = <$fh>) {
            $proxy = $1 if $line =~ m{^export\s+https?_proxy="(http://[\w\.\-]+:[0-9]+)"}isx;
            push @env => $line;
        }
        close $fh;
        AE::log fatal => "couldn't find running process address in %s", $env_file
            unless $proxy;
        if (my $pid = _ping_pid($proxy)) {
            AE::log info => 'running proxy has PID %d', $pid;
            if ($stop) {
                kill INT => $pid;
            } else {
                print for @env;
            }
            exit;
        }
    }

    my $je = _process_wpad($wpad_file);
    my $cv = run($bind_host, $bind_port, $je, sub {
        my (undef, $this_host, $this_port) = @_;
        my @env;
        AE::log info => 'STARTED THE SERVER AT %s:%d', $this_host, $this_port;
        $proxy = 'http://' . $this_host . ':' . $this_port;
        AE::log info => 'writing environment proxy settings to %s', $env_file;
        push @env => qq(export $_="$proxy"\n) for map { $_ => uc } qw(http_proxy https_proxy);
        push @env => qq(export $_="localhost,127.0.0.1"\n) for map { $_ => uc } qw(no_proxy);
        print for @env;
        open(my $fh, '>', $env_file)
            || AE::log fatal => "can't write to %s: %s", $env_file, $@;
        print $fh $_ for @env;
        close $fh;
        _daemonize if $detach;
    });
    $cv->recv;
    exit;
}
