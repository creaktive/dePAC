#!/usr/bin/env perl
use 5.010;
use strict;
use warnings qw(all);
# CORE dependencies
use Getopt::Long;
use IO::Socket;
use Net::Domain;
use POSIX;
# external dependencies
use AnyEvent::HTTP;
use AnyEvent::Socket;
use JE;

main();

sub _help {
    return print <<'END_HELP';
Usage: depac [options]
    --help              This screen
    --quiet             Suppress STDERR output
    --stop              Stop the running instance
    --reload            Reload the running instance
    --status            Output the environment settings if an instance is running
    --wpad_file URL     Manually specify the URL of the "wpad.dat" file (default: DNS autodiscovery)
                        Alternatively: --wpad_file=skip to short-circuit the relay proxy
    --env_file FILE     File for environment persistence (default: ~/.depac.env)
    --nodetach          Do not daemonize
    --bind_host ADDR    Accept connection at this host address (default: 127.0.0.1)
    --bind_port PORT    Accept connection at this port (default: random port)
    --custom DEST,REGEX Custom routes AKA "poor man's WPAD"; overrides for the WPAD rules.
                        DEST is the destination proxy address (or "direct"),
                        REGEX is a regular expression that matches the hostname.
                        Multiple custom routes can be defined adding --custom ...
                        as much as necessary.
                        Example: --custom '192.168.253.15:8080,dev\.company\.com$'

 * Add this line to your ~/.profile file to start the relay proxy in background
   and update HTTP_PROXY environment variables appropriately:

    eval $(depac --quiet)

 * To gracefully terminate the relay proxy and unset HTTP_PROXY environment:

    eval $(depac --stop)
END_HELP
}

# shamelessly stolen from https://metacpan.org/source/MACKENNA/HTTP-ProxyPAC-0.31/lib/HTTP/ProxyPAC/Functions.pm
sub _validIP {
    return ($_[0] =~ m{^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$}x
        && $1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255);
}

our %memoize;
sub _process_wpad {
    my ($wpad_file) = @_;
    return () if $wpad_file && $wpad_file eq 'skip';
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
            my $addr = Socket::inet_aton($_[0]);
            $addr ? inet_ntoa($addr) : ();
        };
    });
    $je->new_function(isInNet => sub {
        $memoize{ join('|', __LINE__, @_) } //= do {
            $_[0] = dnsResolve($_[0]) unless _validIP($_[0]);
            (!$_[0] || !_validIP($_[1]) || !_validIP($_[2]))
                ? () : (Socket::inet_aton($_[0]) & Socket::inet_aton($_[2])) eq (Socket::inet_aton($_[1]) & Socket::inet_aton($_[2]));
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
            my $addr = Socket::inet_aton(Net::Domain::hostname);
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
    if ($wpad_file) {
        AE::log info => 'fetching %s', $wpad_file;
        http_get $wpad_file,
            proxy => undef,
            timeout => 1.0,
            sub {
                my ($body, $hdr) = @_;
                if (($hdr->{Status} != 200) || !length($body)) {
                    AE::log fatal => "couldn't GET %s", $wpad_file;
                } else {
                    $cv->send([$body, "$wpad_file"]);
                }
            };
    } else {
        my $hostdomain  = Net::Domain::hostdomain;
        AE::log info => 'searching domain %s', $hostdomain;
        my @hostdomain = split m{\.}x, $hostdomain;
        while ($#hostdomain) {
            my $wpad = 'http://wpad.' . join('.', @hostdomain) . '/wpad.dat';
            AE::log info => 'fetching %s', $wpad;
            $cv->begin;
            http_get $wpad,
                proxy => undef,
                timeout => 1.0,
                sub {
                    my ($body, $hdr) = @_;
                    $cv->end;
                    if (($hdr->{Status} != 200) || !length($body)) {
                        AE::log debug => "couldn't GET %s", $wpad;
                    } else {
                        $cv->send([$body, "$wpad"]);
                    }
                };
            shift @hostdomain;
        }
    }
    (my $body, $je->{last_working_wpad_file}) = @{ $cv->recv || [''] };
    AE::log fatal => "COULDN'T FIND WPAD" unless $body;
    $je->eval($body);
    AE::log fatal => "COULDN'T EVALUATE WPAD" if $@;
    AE::log info => 'using WPAD %s', $je->{last_working_wpad_file};
    return $je;
}

sub _ping_pid {
    my ($proxy) = @_;
    my $cv = AnyEvent->condvar;
    AE::log info => 'pinging %s:%d', @$proxy;
    http_get 'http://depac/pid',
        proxy   => $proxy,
        timeout => 1.0,
        sub {
            my ($body, $hdr) = @_;
            if (($hdr->{Status} != 200) || !length($body)) {
                AE::log info => "couldn't GET /pid from %s:%d", @$proxy;
                $cv->send(0);
            } else {
                chomp $body;
                $cv->send($body);
            }
        };
    return $cv->recv;
}

our ($sigint, $sighup); # keep the reference
sub run {
    my ($bind_host, $bind_port, $je, $routes, $cb) = @_;
    my (%pool, %status);
    my $cv = AnyEvent->condvar;
    $sighup = AnyEvent->signal(signal => 'HUP', cb => sub {
        AE::log info => 'cleaning up caches...';
        %pool = ();
        %status = ();
        %memoize = ();
        AE::log info => 'reprocessing WPAD %s', $je->{last_working_wpad_file};
        http_get $je->{last_working_wpad_file},
            proxy => undef,
            timeout => 1.0,
            sub {
                my ($body, $hdr) = @_;
                if (($hdr->{Status} != 200) || !length($body)) {
                    AE::log fatal => "couldn't GET %s", $je->{last_working_wpad_file};
                } else {
                    $je->eval($body);
                    AE::log fatal => "COULDN'T EVALUATE WPAD" if $@;
                }
            };
    });
    $sigint = AnyEvent->signal(signal => 'INT', cb => sub {
        AE::log info => 'shutting down...';
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
        $status{connections}++;
        $h->push_read(line => sub {
            my ($_h, $line, $eol) = @_;
            AE::log debug => '[from %s:%d] %s', $host, $port, $line;
            my ($verb, $peer_host, $peer_port, $proto, $uri);
            if ($line =~ m{^CONNECT\s+([\w\.\-]+):([0-9]+)\s+(HTTP/1\.[01])$}ix) {
                ($verb, $peer_host, $peer_port, $proto) = ('CONNECT', $1, $2, $3);
            } elsif ($line =~ m{^(DELETE|GET|HEAD|OPTIONS|POST|PUT|TRACE)\s+(https?)://([\w\.\-]+)(?::([0-9]+))?(\S*)\s+(HTTP/1\.[01])$}ix) {
                ($verb, my $scheme, $peer_host, $peer_port, $uri, $proto) = (uc($1), lc($2), $3, $4, $5, $6);
                $peer_port ||= $scheme eq 'http' ? 80 : 443;
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
            if ($peer_host eq 'depac') {
                $status{cache} = keys %memoize;
                $status{pool} = keys %pool;
                if (my $response = {
                        '/pid'      => sub { $$ },
                        '/status'   => sub { join $eol => map { $_ . "\t" . $status{$_} } sort keys %status },
                    }->{ $uri }) {
                    AE::log info => '%s request from %s:%d (OK)', $uri, $host, $port;
                    $_h->push_write(
                        'HTTP/1.0 200 OK' . $eol .
                        'Cache-Control: no-cache' . $eol .
                        'Connection: close' . $eol .
                        'Content-Type: text/plain' . $eol . $eol .
                        $response->() . $eol
                    );
                } else {
                    AE::log warn => '%s request from %s:%d (Not found)', $uri, $host, $port;
                    $_h->push_write(
                        'HTTP/1.0 404 Not found' . $eol .
                        'Cache-Control: no-cache' . $eol .
                        'Connection: close' . $eol .
                        'Content-Type: text/html' . $eol . $eol .
                        '<html><body><h1>404 Not found</h1></body></html>'
                    );
                }
                $_h->push_shutdown;
                delete $pool{ fileno($fh) };
                return;
            }

            my ($proxy) = map {
                ($peer_host =~ $_->[0]) ? $_->[1] : ()
            } @$routes;
            AE::log debug => 'overriding with %s', $proxy if $proxy;
            $proxy ||= $je ? $je->{FindProxyForURL}->(
                ($verb eq 'CONNECT' ? 'https' : 'http') . '://' . $peer_host, # HACK!
                $peer_host,
            ) : 'DIRECT';
            AE::log debug => 'selected proxy %s', $proxy;

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
                            $line = join ' ', $verb, $uri, $proto;
                            AE::log debug => '[to %s:%d] %s', $peer_host, $peer_port, $line;
                            $peer_h->push_write($line . $eol);
                        }
                        $_h->on_read(sub {
                            my $l = length $_[0]->rbuf;
                            $status{sent_bytes} += $l;
                            AE::log trace => 'send %d bytes to %s:%d', $l, $peer_host, $peer_port;
                            $peer_h->push_write($_[0]->rbuf);
                            $_[0]->rbuf = '';
                        });
                        $peer_h->on_read(sub {
                            my $l = length $_[0]->rbuf;
                            $status{recv_bytes} += $l;
                            AE::log trace => 'recv %d bytes from %s:%d', $l, $peer_host, $peer_port;
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
                            my $l = length $_[0]->rbuf;
                            $status{sent_bytes} += $l;
                            AE::log trace => 'send %d bytes to %s:%d', $l, $proxy_host, $proxy_port;
                            $peer_h->push_write($_[0]->rbuf);
                            $_[0]->rbuf = '';
                        });
                        $peer_h->on_read(sub {
                            my $l = length $_[0]->rbuf;
                            $status{recv_bytes} += $l;
                            AE::log trace => 'recv %d bytes from %s:%d', $l, $proxy_host, $proxy_port;
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
    return;
}

sub main {
    my $bind_host = '127.0.0.1';
    my $env_file = $ENV{HOME} . '/.depac.env';
    my $detach = 1;
    my ($bind_port, $wpad_file, $help, $stop, $reload, $status, $quiet, @custom);
    GetOptions(
        'bind_host=s'   => \$bind_host,
        'bind_port=i'   => \$bind_port,
        'detach!'       => \$detach,
        'env_file=s'    => \$env_file,
        'help'          => \$help,
        'quiet'         => \$quiet,
        'reload'        => \$reload,
        'status'        => \$status,
        'stop'          => \$stop,
        'wpad_file=s'   => \$wpad_file,
        'custom=s'      => \@custom,
    );
    _help && exit if $help;

    my $routes = [];
    for (@custom) {
        my ($dest, $regex) = /^([\w\.:]+),(.+)$/x;
        AE::log fatal => "Bad route: $_" if !$dest || !$regex;
        AE::log debug => "Custom route [ qr/$regex/i => '\Q$dest\E' ]";
        push @$routes => [ qr/$regex/i => $dest ];
    }

    open(\*STDERR, '>', '/dev/null') || AE::log fatal => "dup stdout > stderr: $@"
        if $quiet;
    my $proxy;
    if (-e $env_file) {
        AE::log debug => 'checking previous environment at %s', $env_file;
        open(my $fh, '<', $env_file)
            || AE::log fatal => "can't read from %s: %s", $env_file, $@;
        my @env;
        while (my $line = <$fh>) {
            $proxy = [$1, $2] if $line =~ m{^export\s+https?_proxy="http://([\w\.\-]+):([0-9]+)"}isx;
            push @env => $line;
        }
        close $fh;
        AE::log fatal => "couldn't find running process address in %s", $env_file
            unless $proxy;
        if (my $pid = _ping_pid($proxy)) {
            AE::log info => 'running proxy has PID %d', $pid;
            if ($stop) {
                AE::log debug => 'sending SIGINT to PID %d', $pid;
                kill INT => $pid;
            } elsif ($reload) {
                AE::log debug => 'sending SIGHUP to PID %d', $pid;
                kill HUP => $pid;
            } else {
                print for @env;
            }
            exit;
        }
    }
    exit if $status || $stop; # not running
    my $je = _process_wpad($wpad_file);
    run($bind_host, $bind_port, $je, $routes, sub {
        my (undef, $this_host, $this_port) = @_;
        my @env;
        AE::log info => 'STARTED THE SERVER AT %s:%d', $this_host, $this_port;
        $proxy = 'http://' . $this_host . ':' . $this_port;
        AE::log info => 'writing environment proxy settings to %s', $env_file;
        push @env => qq(export $_="$proxy"\n) for map { $_ => uc } qw(http_proxy https_proxy);
        print for @env;
        umask 077;
        unlink $env_file;
        open(my $fh, '>', $env_file)
            || AE::log fatal => "can't write to %s: %s", $env_file, $@;
        print $fh $_ for @env;
        close $fh;
        _daemonize if $detach;
    })->recv;
    exit;
}
