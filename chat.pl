#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;

use Getopt::Long;
use Pod::Usage;

use AnyEvent::HTTPD;
use AnyEvent::Socket;
use AnyEvent::Handle;
use HTTP::Parser::XS qw(parse_http_request);
use Text::MicroTemplate::File;
use Path::Class qw/file dir/;
use JSON::XS;
use Digest::MD5 qw/md5/;

GetOptions(
    \my %option,
    qw/help port socekt_port host/
);
pod2usage(0) if $option{help};
$option{port}        ||= 9000;
$option{socekt_port} ||= $option{port} + 1;
$option{host}        ||= '0.0.0.0';

my $mtf = Text::MicroTemplate::File->new(
    include_path => ["$FindBin::Bin/templates"],
);
my $js  = JSON::XS->new->utf8;

my $httpd = AnyEvent::HTTPD->new(
    host => $option{host},
    port => $option{port},
);

my @clients;
$httpd->reg_cb(
    '' => sub {
        $_[1]->respond(
            [404, 'not found', { 'Content-Type' => 'text/plain' }, 'not found']
        );
    },

    '/' => sub {
        my ($h, $req) = @_;

        $req->respond({
            content => [
                'text/html; charset=utf-8',
                $mtf->render_file('index.mt'),
            ],
        });
    },

    '/chat' => sub {
        my ($h, $req) = @_;

        my ($room) = $req->url =~ m!^/chat/(.+)!;

        $req->respond(
            [404, 'not found', { 'Content-Type' => 'text/plain' }, 'not found']
        ) unless $room;

        (my $host = $req->headers->{host}) =~ s/:\d+$//;
        $req->respond({
            content => [
                'text/html; charset=utf-8',
                $mtf->render_file('room.mt', $host, $option{socekt_port}, $room),
            ],
        });
    },

    '/static' => sub {
        my ($h, $req) = @_;

        my $static_dir = dir("$FindBin::Bin/static");
        my $file = file("$FindBin::Bin" . $req->url);

        if (-f $file && $static_dir->contains($file->parent)) {
            my $type
                = $file->basename =~ /\.css$/ ? 'text/css'
                : $file->basename =~ /\.js$/  ? 'text/javascript'
                :                               'application/octet-stream';

            $req->respond({
                content => [$type, scalar $file->slurp],
            });
        }

        $req->respond(
            [404, 'not found', { 'Content-Type' => 'text/plain' }, 'not found']
        );
    },
);

my %room;
tcp_server $option{host}, $option{socekt_port}, sub {
    my ($fh, $address) = @_;
    die $! unless $fh;

    my $room;
    my $h = AnyEvent::Handle->new( fh => $fh );
    $h->on_error(sub {
        warn 'err: ', $_[2];
        delete $room{ $room }[fileno($fh)] if $room;
        undef $h;
    });

    $h->push_read( line => qr/\x0d?\x0a\x0d?\x0a/, sub {
        my ($h, $hdr) = @_;

        my $err;
        my $r = parse_http_request($hdr . "\x0d\x0a\x0d\x0a/", \my %env);
        $err++ if $r < 0;
        $err++ unless $env{HTTP_CONNECTION} eq 'Upgrade'
                  and $env{HTTP_UPGRADE} eq 'WebSocket';
        if ($err) {
            undef $h;
            return;
        }

        # handle handshake
        my $k1 = join '', grep /\d/, split '', $env{HTTP_SEC_WEBSOCKET_KEY1};
        my $k2 = join '', grep /\d/, split '', $env{HTTP_SEC_WEBSOCKET_KEY2};
        my $s1 = () = $env{HTTP_SEC_WEBSOCKET_KEY1} =~ /(\s)/g;
        my $s2 = () = $env{HTTP_SEC_WEBSOCKET_KEY2} =~ /(\s)/g;

        my $byte = pack('NN', $k1/$s1, $k2/$s2);

        $h->push_read( chunk => 8, sub {
            my ($h, $chunk) = @_;

            my $handshake = join "\x0d\x0a",
                'HTTP/1.1 101 Web Socket Protocol Handshake',
                'Upgrade: WebSocket',
                'Connection: Upgrade',
                "Sec-WebSocket-Origin: $env{HTTP_ORIGIN}",
                "Sec-WebSocket-Location: ws://$env{HTTP_HOST}$env{PATH_INFO}",
                '', md5($byte . $chunk);
            $h->push_write($handshake);

            # connection ready
            ($room = $env{PATH_INFO}) =~ s!^/!!;
            $room{ $room }[ fileno($fh) ] = $h;

            $h->on_read(sub {
                shift->push_read( line => "\xff", sub {
                    my ($h, $json) = @_;
                    $json =~ s/^\0//;

                    my $data = $js->decode($json);
                    $data->{address} = $address;
                    $data->{time} = time;

                    my $msg = $js->encode($data);

                    # broadcast
                    for my $c (grep { defined } @{ $room{$room} || [] }) {
                        $c->push_write("\x00" . $msg . "\xff");
                    }
                });
            });
        });
    });
};

print "Accepting requests at http://$option{host}:$option{port}/\n";
$httpd->run;

__END__

=head1 NAME

chat.pl - AnyEvent based WebSocket chat demo

=head1 SYNOPSIS

  chat.pl [options]
  
  Options:
      --help          show this help
      --host          address to bind (default 0.0.0.0)
      --port          http port number (default: 9000)
      --socket_port   websocket port number (default: 9001)

=head1 AUTHOR

Daisuke Murase <typester@cpan.org>

=cut
