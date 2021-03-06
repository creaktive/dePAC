# NAME

dePAC - portable CLI solution for Proxy Auto-Config

# VERSION

BETA QUALITY CODE!!! USE AT YOUR OWN RISK!!! PATCHES WELCOME!!!

# SYNOPSIS

    # Wrap the command so it runs through the auto-detected proxy:
    $ depac curl whatismyip.akamai.com
    112.165.140.6

    # Or run as a daemon, for all the processes sharing the user environment:
    $ eval $(depac)

    $ echo $http_proxy
    http://127.0.0.1:56538

    $ curl depac/status
    cache   1495
    connections     14
    pool    1
    recv_bytes      2418844
    sent_bytes      9077

    $ eval $(depac --stop)

# DESCRIPTION

Suppose you are in a corporate network environment and often times find yourself
manually setting/unsetting the HTTP_PROXY environment variable in order to
access different hosts (for instance, _yay proxy_ for the external hosts and
_nay proxy_ for the internal ones). Sounds familiar? In this case, `depac` might
help you.

## The problem

Corporate proxies are meant to steer GUI browser users via
[Proxy Auto-Config](https://en.wikipedia.org/wiki/Proxy_auto-config). In a
nutshell, a browser like Internet Explorer downloads a special routing file
from a virtual host served by the proxy itself. This file consists of a
JavaScript code that usually contains a humongous `if/else if/else` clause
that maps the requested hostname to the address of the proxy host capable of
contacting the requested hostname.

Now, CLI clients don't usually implement JavaScript, and therefore can not
decide which proxy to use by themselves.

## The solution

`depac` uses a portable lightweight (albeit limited)
[JavaScript engine implementation](https://metacpan.org/pod/JE) in order to
parse the PAC file. Then, it creates a relay proxy that forwards the requests to
the routes assigned by the PAC logic.

`depac` is usually started in the beginning of login session, and through use of
environment variables it's relay proxy can be located and automatically used for
all the user agents that do support HTTP_PROXY variables.

(this technique is somewhat similar to what
[ssh-agent](https://en.wikipedia.org/wiki/Ssh-agent) does. In fact, half of the
previous paragraph was stolen from `ssh-agent` manual page :)

The biggest advantage of `depac` in comparison to the similar solutions like
[pac4cli](https://github.com/tkluck/pac4cli) is that the former does not require
a system-wide installation. Both the JavaScript engine *and* the relay proxy are
implemented in pure Perl language and require no dependencies except for
Perl v5.10 itself (which is omnipresent anyway).

# INSTALLATION

    $ curl -o ~/bin/depac https://raw.githubusercontent.com/creaktive/dePAC/master/depac
    $ chmod +x ~/bin/depac
    $ echo 'eval $(~/bin/depac)' >> ~/.profile

Or you can use `wget` and call it with `perl` (feel free to mix):

    $ wget -O ~/depac https://raw.githubusercontent.com/creaktive/dePAC/master/depac
    $ echo 'eval $(perl ~/depac)' >> ~/.profile

You can also use `depac` in an ad-hoc fashion, without a shared instance running
in the background:

    $ depac -- wget -r -np https://something.com

# USAGE

    Usage: depac [options] [command]
        --help              This screen
        --stop              Stop the running instance
        --reload            Reload the running instance
        --status            Output the environment settings if an instance is running
        --wpad_file URL     Manually specify the URL of the "wpad.dat" file (default: DNS autodiscovery)
                            Alternatively: --wpad_file=skip to short-circuit the relay proxy
        --env_file FILE     File for environment persistence (default: ~/.depac.env)
        --log_file FILE     File for the log (default: ~/.depac.log; /dev/null to disable :)
        --log_level LEVEL   fatal/warn/info/debug/trace (default: warn)
        --nodetach          Do not daemonize
        --bind_host ADDR    Accept connection at this host address (default: 127.0.0.1)
        --bind_port PORT    Accept connection at this port (default: random port)
        --custom DEST,REGEX Custom routes AKA "poor man's WPAD"; overrides for the WPAD rules.
                            DEST is the destination proxy address (or "direct"),
                            REGEX is a regular expression that matches the hostname.
                            Multiple custom routes can be defined adding --custom ...
                            as much as necessary.
                            Example: --custom '192.168.253.15:8080,dev\.company\.com$'

     * To run a single process through the relay proxy:

        depac curl ifconfig.me/all

     * Add this line to your ~/.profile file to start the relay proxy in background
       and update HTTP_PROXY environment variables appropriately:

        eval $(depac)

     * To gracefully terminate the relay proxy and unset HTTP_PROXY environment:

        eval $(depac --stop)

# CAVEAT

 - Only DNS is queried for
   [WPAD](https://en.wikipedia.org/wiki/Web_Proxy_Auto-Discovery_Protocol).
   DHCP discovery is not implemented
 - `weekDayRange`, `dateRange` & `timeRange` PAC functions are not implemented
 - The `FindProxyForURL(url, host)` function does not receive the real URL;
   for performance reasons the `url` parameter is the same as `host`
 - The mappings are heavily cached, do run `depac --reload`
   (or `pkill -HUP -f depac`) if the connections start failing
 - `depac` has 300KB of text at the time of writing, because of all the
   libraries bundled with it. The actual source code is `depac.pl`. To use it
   instead, install the Perl dependencies with `cpanm AnyEvent::HTTP JE`
 - *Security!* There's close to none. Shouldn't be much more exploitable than
   a regular GUI browser with an outdated JavaScript engine, tho

# SEE ALSO

 - [pac4cli](https://github.com/tkluck/pac4cli) - Proxy-auto-discovery for command-line applications
 - [Web Proxy Auto-Discovery Protocol](https://en.wikipedia.org/wiki/Web_Proxy_Auto-Discovery_Protocol)
 - [Proxy auto-config](https://en.wikipedia.org/wiki/Proxy_auto-config)

# AUTHOR

Stanislaw Pusep <stas@sysd.org>

# COPYRIGHT AND LICENSE

This software is copyright (c) 2019 by Stanislaw Pusep <stas@sysd.org>.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
