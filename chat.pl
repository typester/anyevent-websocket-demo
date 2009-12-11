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

$httpd->reg_cb(
    '' => sub {
        $_[1]->respond(
            [404, 'not found', { 'Content-Type' => 'text/plain' }, 'not found']
        );
    },

    '/' => sub {
        my ($h, $req) = @_;

        (my $host = $req->headers->{host}) =~ s/:\d+$//;
        $req->respond({
            content => [
                'text/html; charset=utf-8',
                $mtf->render_file('index.mt', $host, $option{socekt_port}),
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

my @clients;
tcp_server $option{host}, $option{socekt_port}, sub {
    my ($fh, $address) = @_;
    die $! unless $fh;

    my $h = AnyEvent::Handle->new( fh => $fh );
    $h->on_error(sub {
        my ($h, $fatal, $msg) = @_;
        warn 'err: ', $msg;
        delete $clients[fileno($fh)];
    });

    $h->push_read( line => qr/\x0d?\x0a\x0d?\x0a/, sub {
        my ($h, $hdr) = @_;

        my $err;
        my $r = parse_http_request($hdr . "\x0d\x0a\x0d\x0a/", \my %env);
        $err++ if $r < 0;
        $err++ unless $env{HTTP_CONNECTION} eq 'Upgrade'
                  and $env{HTTP_UPGRADE} eq 'WebSocket';
        if ($err) {
            delete $clients[fileno($fh)];
            undef $h;
            return;
        }

        my $handshake = join "\x0d\x0a",
            'HTTP/1.1 101 Web Socket Protocol Handshake',
            'Upgrade: WebSocket',
            'Connection: Upgrade',
            "WebSocket-Origin: $env{HTTP_ORIGIN}",
            "WebSocket-Location: ws://$env{HTTP_HOST}$env{PATH_INFO}",
            '', '';
        $h->push_write($handshake);

        # connection ready
        $h->on_read(sub {
            shift->push_read( line => "\xff", sub {
                my ($h, $json) = @_;
                $json =~ s/^\0//;

                my $data = $js->decode($json);
                $data->{address} = $address;
                $data->{time} = time;

                my $msg = $js->encode($data);

                # broadcast
                for my $c (grep { defined } @clients) {
                    $c->push_write("\x00" . $msg . "\xff");
                }
            });
        });
    });

    $clients[ fileno($fh) ] = $h;
};

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
