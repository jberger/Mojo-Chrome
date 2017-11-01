package Mojo::Chrome;

use Mojo::Base 'Mojo::EventEmitter';

use 5.16.0;

our $VERSION = '0.01';
$VERSION = eval $VERSION;

use Carp ();
use Mojo::Chrome::Util;
use Mojo::IOLoop;
use Mojo::IOLoop::Server;
use Mojo::URL;
use Mojo::UserAgent;
use Mojolicious;
use Scalar::Util ();

use constant DEBUG => $ENV{MOJO_CHROME_DEBUG};

has base => sub { Mojo::URL->new };
has chrome_path => sub {
  Mojo::Chrome::Util::chrome_executable()
    or Carp::croak 'chrome_path not set and could not be determined';
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
  )->on(error => sub{ $self->$cb($_[-1]) });
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
  )->on(error => sub{ $self->$cb($_[1]) });
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

L<Mojo::Chrome> is an interface to the Chrome DevTools Protocol which allows interaction with a (possibly headless) chrome instance.
While L<Mojo::Chrome> is primarily intended as a backbone for L<Test::Mojo::Role::Chrome>, this is not its only purpose.

Communication is bidirectional and asynchronous via an internal websocket.
Both request/response and push-events are commonplace, though this module does its best to simplify things.

This module is the spiritual successor to L<Mojo::Phantom> which interfaced with the headless phantomjs application.
That project was abandoned after the headless chrome functionality was announced.

L<Mojo::Phantom> had many short-cuts that were intended to smooth out the experience since communication was essentially unidirectional after the page load and the process or at least the page state was ephemeral.
Because of the robust communication afforded by the Chrome DevTools Protocol many of those short-cuts will not be replicated for C<Mojo::Chome>.
However with the increased power the author suspects that new short-cuts will be desirable, suggestions are welcome.

=head1 CAVEATS

This module is new and changes may occur.
High level functionality should be fairly stable.

The protocol itself is fairly new and largely undocumented, especially in usage documentation.
If this module skews from the protocol in newer versions of chrome please alert the author via the bug tracker.
Incompatibilites can hopefully be smoothed out in the module however where this isn't possible the author intends to target newer versions of chrome rather than support a long tail of chrome version.

=head1 EVENTS

L<Mojo::Chrome> inherits all of the events from L<Mojo::EventEmitter>.
Further it emits events that arrive from the protocol as they arrive.
Per the protocol most events are disabled initially, though some methods will enable and subscribe to events as a matter of course.

Eventually this documentation might suggest best practices or contain other functionality to moderate events.
For the time being simply consider that fact, especially when disabling protocol events.

=head1 ATTRIBUTES

L<Mojo::Chrome> inherits all of the attributes from L<Mojo::EventEmitter> and implements the following new ones.

=head2 base

A base url used to make relative urls absolute.
Must be an instance of L<Mojo::URL> or api compatible class.

=head2 chrome_path

Path to the chrome executable.
Default is to use L<Mojo::Chrome::Util/chrome_executable> to discover it.

=head2 chrome_options

An array reference containing additional command line arguments to pass when executing chrome.
The default includes C<--headless>, it does not include C<--disable-gpu> thought that is a common usage.

=head2 host

The IP address of the host running chrome.
By default this is C<127.0.0.1>, namely the current host.

=head2 port

The port of the chrome process.
The default is to open an unused port.
This should be specified if a remote chrome instance (see C</host>).

=head2 tx

The L<Mojo::Transaction> object maintaining the websocket connection to chrome.

=head2 ua

The L<Mojo::UserAgent> object used to open the connection to chrome if necessary.

=head1 METHODS

L<Mojo::Chrome> inherits all of the methods from L<Mojo::EventEmitter> and implements the following new ones.

=head2 evaluate

  $chrome->evaluate('JS', sub { my ($chrome, $error, $value) = @_; ... });
    Array.from(document.getElementsByTagName('p')).map(e => e.innerText);
  JS

Evaluate a javascript snippet and return the result of the last statement.
If passed a hash reference this is assumed to be arguments passed to DevTools' L<Runtime.evaluate|https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-evaluate>.
Otherwise the value is assumed to be the expression (and the C<returnByValue> option will be set to true).
The callback will receive the invocant, any error, then the value of the last evaluated statement.

Note that other complex behaviors are possible when explicitly passing your own arguments, so please investigate those if this behavior seems limiting.

=head2 load_page

  $chrome->load_page($url, sub { my ($chrome, $error) = @_; ... });

Request a page and load the result, evaluating any initial javascript in the process.
This subscribes to L<Page|https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-enable> events and then requests the page with L<Page.naviate|https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-navigate>.
It then invokes the callback when the appropriate L<Page.frameStoppedLoading|https://chromedevtools.github.io/devtools-protocol/tot/Page/#event-frameStoppedLoading> event is caught.

If passed a hash reference this is assumed to the the arguments passed to the C<Page.navigate> method.
Otherwise the value is assumed to the be url to load.
If the url (given either way) is relative, it will be made absolute using the L</base> url.

=head2 send_command

  $chrome->send_command($method, $params, sub { my ($chrome, $error, $result) = @_; ... });

A lower level method to send a command via the protocol.
The arguments are a method and a hash reference of parameters.
If given, a callback will be invoked when a response is received (N.B. issuing ids and watching for responses is handled transparently internally).
The callback is passed the invocant, any error, and the result.

This method lets you interact with the protocol and while it does simplify some of that process it is still quite low level.

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
