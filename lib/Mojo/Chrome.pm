package Mojo::Chrome;

use Mojo::Base 'Mojo::EventEmitter';

use 5.16.0;

use Carp ();
use Mojo::IOLoop;
use Mojo::IOLoop::Server;
use Mojo::URL;
use Mojo::UserAgent;
use Scalar::Util ();

has host => '127.0.0.1';
has port => sub { Mojo::IOLoop::Server->generate_port };
has 'tx';
has ua   => sub { Mojo::UserAgent->new };

# high level method to load a page
# takes the same arguments as Page.navigate
sub load_page {
  my ($self, $navigate, $cb) = @_;
  Scalar::Util::weaken $self;
  Mojo::IOLoop->delay(
    sub { $self->send_command('Page.enable', shift->begin) }, # ensure we get updates
    sub {
      my ($delay, $err) = @_;
      die $err if $err;
      $self->send_command('Page.navigate', $navigate, shift->begin);
    },
    sub {
      my ($delay, $err, $result) = @_;
      die $err if $err;
      die 'No frameId was received'
        unless my $frame_id = $result->{frameId};
      my $end = $delay->begin(0);
      $self->on('Page.frameStoppedLoading', sub {
        my ($self, $params) = @_;
        return unless $params->{frameId} = $frame_id;
        $self->unsubscribe('Page.frameStoppedLoading', __SUB__);
        $end->();
      });
    },
    sub { $self->$cb(undef) },
  )->catch(sub{ $self->$cb($_[-1]) })->wait;
}

sub send_command {
  my $cb = ref $_[-1] eq 'CODE' ? pop : sub {};
  my ($self, $method, $params) = @_;
  my $payload = {
    method => $method,
    params => $params,
  };
  $self->_send($payload, sub {
    my ($self, $error, $json) = @_;
    # can errors come on the json result?
    $self->$cb($error, $json ? $json->{result} : undef);
  });
}

sub _connect {
  my ($self, $cb) = @_;
  my $url = Mojo::URL->new->host($self->host)->port($self->port)->scheme('http')->path('/json');

  Scalar::Util::weaken $self;
  Mojo::IOLoop->delay(
    sub { $self->ua->get($url, shift->begin) },
    sub {
      my ($delay, $tx) = @_;
      die 'Initial request failed' unless $tx->success;
      my $ws = $tx->res->json('/0/webSocketDebuggerUrl');
      $self->ua->websocket($ws, $delay->begin);
    },
    sub {
      my (undef, $tx) = @_;
      $tx->on(json => sub {
        my (undef, $payload) = @_;
        if (my $id = delete $payload->{id}) {
          my $cb = delete $self->{cb}{$id};
          return $self->emit(error => "callback not found: $id") unless $cb;
          $self->$cb(undef, $payload);
        } elsif (exists $payload->{method}) {
          $self->emit(@{$payload}{qw/method params/});
        } else {
          $self->emit(error => 'message not understood', $payload);
        }
      });
      $tx->on(finish => sub { delete $self->{tx} });
      $self->tx($tx);
      $self->$cb(undef);
    },
  )->catch(sub{ $self->$cb($_[1]) })->wait;
}

sub _send {
  my ($self, $payload, $cb) = @_;

  return $self->_connect(sub{
    my ($self, $err) = @_;
    return $self->$cb($err, undef) if $err;
    $self->_send($payload, $cb);
  }) unless my $tx = $self->tx;

  my $id = ++$self->{id};
  $self->{cb}{$id} = $cb;
  $tx->send({json => {%$payload, id => $id}});
}

1;

=head1 NAME

Mojo-Chrome - A Mojo interface to Chrome DevTools Protocol

=head1 DESCRIPTION

=head1 PROTOCOL DOCUMENTATION

=over

=item L<https://chromedevtools.github.io/devtools-protocol>

=item L<https://developers.google.com/web/updates/2017/04/headless-chrome>

=back

=head1 SOURCE REPOSITORY

L<http://github.com/jberger/Mojo-Chrome>

=head1 AUTHOR

Joel Berger, E<lt>joel.a.berger@gmail.comE<gt>

=head1 CONTRIBUTORS

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2017 by L</AUTHOR> and L</CONTRIBUTORS>.
This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.
