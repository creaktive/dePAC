package AnyEvent;
sub common_sense{}
sub CYGWIN      (){ 0 }
sub WIN32       (){ 0 }
sub F_SETFD     (){ eval { Fcntl::F_SETFD() } || 2 }
sub F_SETFL     (){ eval { Fcntl::F_SETFL() } || 4 }
sub O_NONBLOCK  (){ eval { Fcntl::O_NONBLOCK() } || 04000 }
sub FD_CLOEXEC  (){ eval { Fcntl::FD_CLOEXEC() } || 1 }
package AnyEvent::Base;
sub WNOHANG     (){ eval { POSIX::WNOHANG() } || 1 }
package AnyEvent::IO;
sub O_RDONLY    (){ eval { Fcntl::O_RDONLY() } || 0 }
sub O_WRONLY    (){ eval { Fcntl::O_WRONLY() } || 1 }
sub O_RDWR      (){ eval { Fcntl::O_RDWR  () } || 2 }
sub O_CREAT     (){ eval { Fcntl::O_CREAT () } || 64 }
sub O_EXCL      (){ eval { Fcntl::O_EXCL  () } || 128 }
sub O_TRUNC     (){ eval { Fcntl::O_TRUNC () } || 512 }
sub O_APPEND    (){ eval { Fcntl::O_APPEND() } || 1024 }
package AnyEvent::Util;
sub WSAEINVAL   (){ -1e99 }
sub WSAEWOULDBLOCK(){ -1e99 }
sub WSAEINPROGRESS(){ -1e99 }
sub _AF_INET6   (){ 30 }
1;
