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
use HTTP::Response;

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

sub _start {
    my ($my_handle) = @_;
    return $my_handle->push_read(regex => qr{(\015?\012){2}}x, sub {
        my ($h, $data) = @_;
        my ($req, $hdr) = split m{\015?\012}x, $data, 2;
        $req =~ s/\s+$//sx;
        AE::log debug => "request: [$req]\n";
        if ($hdr =~ m{\bContent-length:\s*(\d+)\b}isx) {
            AE::log debug => "expecting content\n";
            $h->push_read(chunk => int($1), sub {
                my ($peer_h, $_data) = @_;
                _reply($peer_h, $req, $hdr, $_data);
            });
        } else {
            _reply($h, $req, $hdr);
        }
    });
}

sub _cleanup {
    my ($h) = @_;
    AE::log debug => "closing connection\n";
    my $r = eval {
        ## no critic (ProhibitNoWarnings)
        no warnings;

        my $id = fileno($h->{fh});
        delete $pool{$id};
        shutdown $h->{fh}, 2;

        return 1;
    };
    AE::log warn => "shutdown() aborted\n"
        if not defined $r or $@;
    $h->destroy;
    return;
}

sub _reply {
    my ($h, $req, $hdr, $content) = @_;

    my ($method, $peer_host, $peer_port);
    if ($req =~ m{^(DELETE|GET|HEAD|OPTION|POST|PUT)\s+(https?://.+)\s+(HTTP/1\.[01])$}i) {
        ($method, my $uri, my $protocol) = ($1, $2, $3);
        my $url = URI->new($uri);
        $peer_host = $url->host;
        $peer_port = $url->port;
    } elsif ($req =~ m{^(CONNECT)\s+([\w\.\-]+):(\d+)\s+(HTTP/1\.[01])$}i) {
        ($method, $peer_host, $peer_port, my $protocol) = ($1, $2, $3);
    } else {
        AE::log error => "bad request\n";
        $h->push_write(
            HTTP::Response->new(
                400 => 'Bad Request',
                undef, 'Bad Request'
            )->as_string("\r\n")
        );
        _cleanup($h);
    }

    my $proxy = FindProxyForURL($peer_host, $peer_host);
    AE::log debug => "WPAD says we should use $proxy";

    my ($proxy_host, $proxy_port) = ($proxy =~ m{^PROXY\s+([\w\.]+):([0-9]+)}i);
    AE::log debug => "connecting to $peer_host:$peer_port via $proxy_host:$proxy_port\n";

    my $peer_h;
    $peer_h = AnyEvent::Handle->new(
        connect     => [$proxy_host => $proxy_port],
        on_eof      => sub {
            $peer_h->destroy;
            _cleanup($h);
        },
        on_error    => sub {
            $peer_h->destroy;
            _cleanup($h);
        },
        on_connect  => sub {
            AE::log debug => "connected to $proxy_host:$proxy_port\n";

            if ($method eq 'CONNECT') {
                $peer_h->push_write($req . ("\r\n" x 2));
            } else {
                $peer_h->push_write($req . "\r\n" . $hdr . ("\r\n" x 2) . ($content // ''));
            }

            $h->on_read(
                sub {
                    AE::log debug => "send to $proxy_host:$proxy_port\n";
                    $peer_h->push_write($_[0]->rbuf);
                    $_[0]->rbuf = '';
                }
            );

            $peer_h->on_read(
                sub {
                    AE::log debug => "recv from $proxy_host:$proxy_port\n";
                    $h->push_write($_[0]->rbuf);
                    $_[0]->rbuf = '';
                }
            );
        }
    );
}

my $wpad = URI->new('http://wpad.' . Net::Domain::hostdomain);
$wpad->path('/wpad.dat');

AE::log debug => "fetching $wpad";

my $cv = AnyEvent->condvar;
http_get $wpad->canonical->as_string => sub {
    my ($body, $hdr) = @_;
    if (($hdr->{Status} != 200) || !length($body)) {
        AE::log fatal => "couldn't GET $wpad";
    }

    AE::log debug => "evaluating $wpad";
    $je->eval($body);
    $cv->send;
};
$cv->recv;

AE::log debug => 'STARTING THE SERVER';

my $srv = tcp_server(
    '127.0.0.1' => 8888,
    sub {
        my ($fh, $host, $port) = @_;
        if (scalar keys %pool > $maxconn) {
            AE::log error =>
                "deny connection from $host:$port (too many connections)\n";
            return;
        } else {
            AE::log warn =>
                "new connection from $host:$port\n";
        }

        my $h = AnyEvent::Handle->new(
            fh          => $fh,
            on_eof      => \&_cleanup,
            on_error    => \&_cleanup,
            timeout     => $timeout,
        );

        $pool{fileno($fh)} = $h;
        AE::log debug =>
            sprintf "%d connection(s) in pool\n", scalar keys %pool;

        _start($h);
    }
);
AE->cv->wait;
