#!/usr/bin/env perl
use 5.018;
use strict;
use warnings qw(all);

use AnyEvent;
use AnyEvent::HTTP;
use AnyEvent::Handle;
use AnyEvent::Log;
use AnyEvent::Socket;
use AnyEvent::Util;

use JE;
use Memoize;
use Net::Domain;
use URI;

my %pool;
my $maxconn = 100;
my $timeout = 10;

my $je = JE->new;

sub dnsDomainIs {
    my $host_len = length $_[0];
    my $domain_len = length $_[1];
    my $d = length($_[0]) - length($_[1]);
    return ($d >= 0) && (substr($_[0], $d) eq $_[1]);
}
memoize('dnsDomainIs');
$je->new_function(dnsDomainIs => \&dnsDomainIs);

sub isPlainHostName {
    return index($_[0], '.') == -1;
}
memoize('isPlainHostName');
$je->new_function(isPlainHostName => \&isPlainHostName);

sub shExpMatch {
    $_[1] =~ s{ \* }{.*?}gx;
    return !!($_[0] =~ m{$_[1]}ix);
}
memoize('shExpMatch');
$je->new_function(shExpMatch => \&shExpMatch);

sub FindProxyForURL {
    return $je->{FindProxyForURL}->(@_[0, 1]);
}
memoize('FindProxyForURL', NORMALIZER => sub { join('|', @_) });

sub _cleanup {
    my ($h) = @_;
    AE::log debug => 'closing connection';
    my $r = eval {
        ## no critic (ProhibitNoWarnings)
        no warnings;

        my $id = fileno($h->{fh});

        delete $pool{$id};
        shutdown $h->{fh}, 2;

        return 1;
    };
    AE::log warn => 'shutdown() aborted'
        if !defined($r) || $@;
    $h->destroy;
    return;
}

my $wpad = URI->new('http://wpad.' . Net::Domain::hostdomain);
$wpad->path('/wpad.dat');

AE::log info => 'fetching %s', $wpad;

my $cv = AnyEvent->condvar;
http_get $wpad->canonical->as_string => sub {
    my ($body, $hdr) = @_;
    if (($hdr->{Status} != 200) || !length($body)) {
        AE::log fatal => "couldn't GET %s", $wpad;
    }

    AE::log debug => 'evaluating %s', $wpad;
    $je->eval($body);
    $cv->send;
};
$cv->recv;

AE::log info => 'STARTING THE SERVER';

my $srv = tcp_server(
    '127.0.0.1' => 8888,
    sub {
        my ($fh, $host, $port) = @_;
        if ($maxconn <= scalar keys %pool) {
            AE::log error => 'deny connection from %s:%d (too many connections)', $host, $port;
            return;
        } else {
            AE::log info => 'new connection from %s:%d', $host, $port;
        }

        my $h = AnyEvent::Handle->new(
            fh          => $fh,
            on_eof      => \&_cleanup,
            on_error    => \&_cleanup,
            timeout     => $timeout,
        );

        $pool{fileno($fh)} = $h;
        AE::log debug => 'connection(s) in pool: %d', scalar keys %pool;

        $h->push_read(line => sub {
            my ($_h, $line, $eol) = @_;
            AE::log debug => '[from %s:%d] %s', $host, $port, $line;

            my $url;
            my ($verb, $peer_host, $peer_port, $proto);
            if ($line =~ m{^(DELETE|GET|HEAD|OPTION|POST|PUT)\s+(https?://.+)\s+(HTTP/1\.[01])$}i) {
                $url = URI->new($2);
                ($verb, $peer_host, $peer_port, $proto) = ($1, $url->host, $url->port, $3);
            } elsif ($line =~ m{^CONNECT\s+([\w\.\-]+):([0-9]+)\s+(HTTP/1\.[01])$}i) {
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
                return _cleanup($_h);
            }

            my $proxy = 'DIRECT';#FindProxyForURL($peer_host, $peer_host);
            AE::log debug => 'WPAD says we should use %s', $proxy;

            my $peer_h;
            if (uc($proxy) eq 'DIRECT') {
                AE::log debug => 'connecting directly to %s:%d', $peer_host, $peer_port;

                $peer_h = AnyEvent::Handle->new(
                    connect     => [$peer_host => $peer_port],
                    on_eof      => sub {
                        $peer_h->destroy;
                        _cleanup($_h);
                    },
                    on_error    => sub {
                        $peer_h->destroy;
                        _cleanup($_h);
                    },
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
                my ($proxy_host, $proxy_port) = ($proxy =~ m{^PROXY\s+([\w\.]+):([0-9]+)}i);
                AE::log debug => 'connecting to %s:%d via %s:%d', $peer_host, $peer_port, $proxy_host, $proxy_port;

                $peer_h = AnyEvent::Handle->new(
                    connect     => [$proxy_host => $proxy_port],
                    on_eof      => sub {
                        $peer_h->destroy;
                        _cleanup($_h);
                    },
                    on_error    => sub {
                        $peer_h->destroy;
                        _cleanup($_h);
                    },
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
    }
);
AE->cv->wait;
