package Mojo::Chrome;

use Mojo::Base 'Mojo::EventEmitter';

use 5.16.0;

use Carp ();
use IPC::Cmd ();
use Mojo::IOLoop;
use Mojo::IOLoop::Server;
use Mojo::URL;
use Mojo::UserAgent;
use Mojolicious;
use Scalar::Util ();

use constant DEBUG => $ENV{MOJO_CHROME_DEBUG};

has base => sub { Mojo::URL->new };
has chrome_path => sub {
  my $path = $^O eq 'darwin'
    ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
    : IPC::Cmd::can_run 'google-chrome';
  return $path if $path && -f $path && -x _;
  die 'chrome_path not set and could not be determined';
};
has chrome_options => sub { ['--headless' ] }; # '--disable-gpu'
has host => '127.0.0.1';
has [qw/port tx/];
has ua   => sub { Mojo::UserAgent->new };

# high level method to evaluate jacascript in the page context
# error is structured, Mojo::Chrome errors are upgraded to it with exceptionId set to -1
sub evaluate {
  my ($self, $js, $cb) = @_;

  # string value is a javascript expression
  $js = { expression => $js, returnByValue => \1 } unless ref $js eq 'HASH';

  $self->send_command('Runtime.evaluate', $js, sub {
    my ($self, $err, $payload) = @_;
    if ($err && !ref $err) {
      $err = { exceptionId => -1, text => $err };
    } elsif (exists $payload->{exceptionId}) {
      $err = $payload;
    }
    return $self->$cb($err, undef) if $err;
    $self->$cb(undef, $payload->{result}{value});
  });
}

# high level method to load a page
# takes url or a hash accepting the same arguments as Page.navigate
sub load_page {
  my ($self, $nav, $cb) = @_;

  # strings etc are url
  $nav = { url => $nav } unless ref $nav eq 'HASH';

  my $url = Mojo::URL->new("$nav->{url}");
  unless ($url->is_abs) {
    my $base = $self->base;
    $url = $url->scheme($base->scheme)->host($base->host)->port($base->port);
  }
  $nav->{url} = $url->to_string;

  Scalar::Util::weaken $self;
  Mojo::IOLoop->delay(
    sub { $self->send_command('Page.enable', shift->begin) }, # ensure we get updates
    sub {
      my ($delay, $err) = @_;
      die $err if $err;
      $self->send_command('Page.navigate', $nav, shift->begin);
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
  )->catch(sub{ $self->$cb($_[-1]) });
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
  Scalar::Util::weaken $self;

  Mojo::IOLoop->delay(
    sub {
      my $delay = shift;

      # there can't be a targeted running chrome if there is no port
      return $delay->pass(undef) unless my $port = $self->port;

      # otherwise try to connect to an existing chrome (perhaps one we've already spawned)
      my $url = Mojo::URL->new->host($self->host)->port($port)->scheme('http')->path('/json');
      say STDERR "Initial request to chrome: $url" if DEBUG;
      $self->ua->get($url, $delay->begin);
    },
    sub {
      my ($delay, $tx) = @_;

      unless ($tx && $tx->success) {
        # die if we already tried to spawn chrome
        die 'Initial request to chrome failed' if $self->{pid};

        # otherwise try to spawn chrome then come back
        return $self->_spawn(sub{
          my ($self, $err) = @_;
          $err ? $self->$cb($err) : $self->_connect($cb);
        });
      }

      my $ws = $tx->res->json('/0/webSocketDebuggerUrl');
      die 'Could not determine websocket url to chrome dev tools' unless $ws;
      say STDERR "Connecting to chrome devtools via websocket: $ws" if DEBUG;
      $self->ua->websocket($ws, $delay->begin);
    },
    sub {
      my (undef, $tx) = @_;
      Mojo::IOLoop->stream($tx->connection)->timeout(0);

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
  )->catch(sub{ $self->$cb($_[1]) });
}

sub _kill {
  my ($self) = @_;
  return unless my $pid = delete $self->{pid};
  print STDERR "Killing $pid\n" if DEBUG;
  kill KILL => $pid;
  waitpid $pid, 0;
  delete $self->{pipe};
  delete $self->{port} if delete $self->{port_generated};
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
  say STDERR 'Attempting to spawn chrome' if DEBUG;
  Scalar::Util::weaken $self;

  # once chrome has started up it will call this server
  # that call let's us know that it is up and going
  my $start_server = Mojo::Server::Daemon->new(silent => 1);
  $start_server
    ->app(Mojolicious->new)->app
    ->tap(sub{$_->log->level('fatal')})
    ->routes
    ->get('/' => sub {
      my $c = shift;
      say STDERR 'Got start server request from chrome' if DEBUG;
      $c->tx->on(finish => sub { $self->$cb(); undef $start_server; });
      $c->rendered(204);
    });
  my $start_port = $start_server->listen(["http://127.0.0.1"])->start->ports->[0];

  my $ws_port = $self->port;
  unless ($ws_port) {
    # if the user didn't designate the port then generate one
    # and note that it was generated so we can clean it up later
    $self->{port_generated} = 1;
    $ws_port = $self->port(Mojo::IOLoop::Server->generate_port)->port;
  }

  my @command = ($self->chrome_path, @{ $self->chrome_options }, "--remote-debugging-port=$ws_port", "http://127.0.0.1:$start_port");
  say STDERR 'Spawning: ' . (join ', ', map { "'$_'" } @command) if DEBUG;
  $self->{pid} = open $self->{pipe}, '-|', @command;

  unless (defined $self->{pid}) {
    my $err = "Could not spawn chrome: $?";
    Mojo::IOLoop->next_tick(sub{ $self->$cb($err) });
  }
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
