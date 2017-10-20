package Mojo::Chrome;

use Mojo::Base 'Mojo::EventEmitter';

use 5.16.0;

use Carp ();
use Mojo::IOLoop;
use Mojo::IOLoop::Server;
use Mojo::URL;
use Mojo::UserAgent;
use Mojolicious;
use Scalar::Util ();

use constant DEBUG => $ENV{MOJO_CHROME_DEBUG};

has chrome_path => sub { die 'chrome_path not set' };
has chrome_options => sub { ['--headless' ] }; # '--disable-gpu'
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
        print STDERR 'Received: ' . Mojo::Util::dumper $payload if DEBUG;
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

sub _kill {
  my ($self) = @_;
  return unless my $pid = delete $self->{pid};
  print STDERR "Killing $pid\n" if DEBUG;
  kill KILL => $pid;
  waitpid $pid, 0;
  delete $self->{pipe};
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
  my $send = {%$payload, id => $id};
  print STDERR 'Sending: ' . Mojo::Util::dumper $send if DEBUG;
  $tx->send({json => $send});
}

sub _spawn {
  my ($self, $cb) = @_;
  Scalar::Util::weaken $self;

  # once chrome has started up it will call this server
  # that call let's us know that it is up and going
  my $start_server = Mojo::Server::Daemon->new(silent => 1);
  $start_server->app(Mojolicious->new)->app->routes->get('/' => sub {
    my $c = shift;
    $c->tx->on(finish => sub { $self->$cb(); undef $start_server; });
    $c->rendered(204);
  });
  my $start_port = $start_server->listen(["http://127.0.0.1"])->start->ports->[0];

  my $ws_port = $self->port;
  my @command = ($self->chrome_path, @{ $self->chrome_options }, "--remote-debugging-port=$ws_port", "http://127.0.0.1:$start_port");
  say STDERR 'Spawning: ' . (join ', ', map { "'$_'" } @command) if DEBUG;
  $self->{pid} = open $self->{pipe}, '-|', @command;
  die 'Could not spawn' unless defined $self->{pid};
}

sub DESTROY {
  return if defined ${^GLOBAL_PHASE} && ${^GLOBAL_PHASE} eq 'DESTRUCT';
  shift->_kill;
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
