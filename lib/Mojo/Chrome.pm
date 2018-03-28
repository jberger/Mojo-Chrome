package Mojo::Chrome;

use Mojo::Base 'Mojo::EventEmitter';

use 5.16.0;

our $VERSION = '0.01';
$VERSION = eval $VERSION;

use Carp ();
use IPC::Cmd ();
use List::Util ();
use Mojo::IOLoop;
use Mojo::IOLoop::Server;
use Mojo::URL;
use Mojo::UserAgent;
use Mojolicious;
use Scalar::Util ();

use constant DEBUG => $ENV{MOJO_CHROME_DEBUG};

has [qw/tx/];
has arguments => sub { ['--headless'] };
has base => sub { Mojo::URL->new };
has executable => sub {
  shift->detect_chrome_executable()
    or Carp::croak 'executable not set and could not be determined';
};
has ua  => sub { Mojo::UserAgent->new };
has target => sub { Mojo::URL->new('http://127.0.0.1') };

sub detect_chrome_executable {
  # class method, no args
  return $ENV{MOJO_CHROME_EXECUTABLE} if $ENV{MOJO_CHROME_EXECUTABLE};

  my $path = IPC::Cmd::can_run 'google-chrome';
  return $path if $path && -f $path && -x _;

  if ($^O eq 'darwin') {
    $path = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    return $path if $path && -f $path && -x _;
  }

  return undef;
}

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
  )->catch(sub{ $self->$cb(pop) });
}

sub from_url {
  my ($self, $url) = @_;
  $url = Mojo::URL->new("$url");

  # target
  my $target = Mojo::URL->new;
  $target->$_($url->$_()) for qw/scheme host port/;
  $self->target($target);

  # executable
  my $params = $url->query;
  if (my $exe = $params->param('executable')) {
    $self->executable($exe);
    $params->remove('executable');
  }

  # headless / no-headless
  $params->append('headless' => '')
    unless defined $params->param('no-headless') || defined $params->param('headless');
  $params->remove('no-headless');

  # arguments
  my @options = List::Util::pairmap { "--$a" . (length $b ? "=$b" : '') } @{ $params->pairs };
  $self->arguments(\@options);

  return $self;
}

sub new {
  my $self = shift;
  return $self->SUPER::new->from_url($_[0]) if @_ == 1 && ref $_[0] ne 'HASH';
  return $self->SUPER::new(@_);
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
      my $url = $self->target;
      return $delay->pass(undef) unless my $port = $url->port || $self->{port};

      # otherwise try to connect to an existing chrome (perhaps one we've already spawned)
      $url = $url->clone->port($port)->path('/json')->query('');
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
  )->catch(sub{ $self->$cb(pop) });
}

sub _kill {
  my ($self) = @_;
  return unless my $pid = delete $self->{pid};
  print STDERR "Killing $pid\n" if DEBUG;
  kill KILL => $pid;
  waitpid $pid, 0;
  delete $self->{pipe};
  delete $self->{port};
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
      $c->tx->on(finish => sub { $self->$cb(undef); undef $start_server; });
      $c->rendered(204);
    });
  my $start_port = $start_server->listen(["http://127.0.0.1"])->start->ports->[0];

  my $url  = $self->target->clone;
  my $port = $url->port;
  unless ($port) {
    # if the user didn't designate the port then generate one
    # we store it so that we can connect again later if the connection is lost
    # however it will be removed if the process is killed
    $port = $self->{port} = Mojo::IOLoop::Server->generate_port;
  }

  my @command = ($self->executable, @{ $self->arguments }, "--remote-debugging-port=$port", "http://127.0.0.1:$start_port");
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

=head1 SYNOPSIS

  # This is the example from https://medium.com/@lagenar/using-headless-chrome-via-the-websockets-interface-5f498fb67e0f
  # of fetching the news headline from Google News. It should not be used as anything but an example.
  # It is archived at https://web.archive.org/web/20171020022803/https://medium.com/@lagenar/using-headless-chrome-via-the-websockets-interface-5f498fb67e0f

  use Mojo::Base -strict;

  use Mojo::Chrome;
  use Mojo::IOLoop;

  binmode(STDOUT, ":utf8");
  $|++;

  my $chrome = Mojo::Chrome->new->catch(sub{ warn pop });
  my $url = 'https://news.google.com/news/?ned=us&hl=en';

  Mojo::IOLoop->delay(
    sub { $chrome->load_page($url, shift->begin) },
    sub {
      my ($delay, $err) = @_;
      die $err if $err;
      $chrome->evaluate(<<'    JS', $delay->begin);
        var sel = '[role="heading"][aria-level="2"]';
        var headings = document.querySelectorAll(sel);
        [].slice.call(headings).map((link)=>{return link.innerText});
      JS
    },
    sub {
      my ($delay, $err, $result) = @_;
      die Mojo::Util::dumper $err if $err;
      say for @$result;
    }
  )->catch(sub{ warn pop })->wait;

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

Errors are basically the wild west.
While methods should have error slots where errors should arrive, whether they do or not is up in the air.
This is especially true of errors that eminate from within the protocol itself.
Certainly this will need to be improved but it is difficult with the protocol documentation in its current state.
Pull requests and other constructive comments are always welcome.

=head1 CONNECTING AND SPAWNING

This module attempts to connect and/or reconnect to Chrome's DevTools Protocol and even spawn an instance of Chrome so as to make that as seemless as possible to the user.
Any method that sends a command will first check for a connection and if it doesn't exist attempt to create one.
Further if a connection can't be made or if a port to connect on hasn't been specified it will spawn a new instance.
In the case that no port was specified a random free port will be used.
(Note that an additional randomly selected free port is used during startup and is then dropped once the startup is complete.)

All this should be as transparent and "do what I mean" as possible.

=head1 EVENTS

L<Mojo::Chrome> inherits all of the events from L<Mojo::EventEmitter>.
Further it emits events that arrive from the protocol as they arrive.
Per the protocol most events are disabled initially, though some methods will enable and subscribe to events as a matter of course.

Eventually this documentation might suggest best practices or contain other functionality to moderate events.
For the time being simply consider that fact, especially when disabling protocol events.

=head1 ATTRIBUTES

L<Mojo::Chrome> inherits all of the attributes from L<Mojo::EventEmitter> and implements the following new ones.

=head2 arguments

An array reference of command line arguments passed to the L</executable> if a chrome process is spawned.
Therefore the default contains only C<--headless>.
A useful option to consider is C<--disable-gpu> which is not enabled by default.
Note that C<--remote_debugging_port> should not be given, use the L</target>'s port value instead.

=head2 base

A base url used to make relative urls absolute.
Must be an instance of L<Mojo::URL> or api compatible class.

=head2 executable

The name of the chrome executable (if it is in the C<$PATH>) or an absolute path to the chrome executable.
Default is to use L</detect_chrome_executable> to discover it.
If unset and not detectable, throws an exception when used.

=head2 tx

The L<Mojo::Transaction> object maintaining the websocket connection to chrome.

=head2 ua

The L<Mojo::UserAgent> object used to open the connection to chrome if necessary.

=head2 target

An instance of L<Mojo::URL> (or api compatible class) used to contact a running process of chrome.
If one is not specified a new chrome process will be spawned on a random port.
If the port is specifed but cannot be contacted then a new chrome process will be spawned using that port.
Default is C<http://127.0.0.1>.

=head1 CLASS METHODS

=head2 detect_chrome_executable

  my $path = Mojo::Chrome->detect_chrome_executable;

Returns the path of the chrome executable to be used.
The following heuristic is used:

=over

=item *

If the environment variable C<MOJO_CHROME_EXECUTABLE> is set that is immediately returned, no check is performed.

=item *

If an executable file named C<google-chrome> exists in your PATH (as determined by L<IPC::Cmd/can_run>) and is executable, then that path is returned.

=item *

If the system is C<darwin> (i.e. Mac), then if C</Applications/Google Chrome.app/Contents/MacOS/Google Chrome> exists and is executable, then that path is returned.

=item *

Otherwise returns C<undef>.

=back

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

=head2 from_url

  my $chrome = Mojo::Chrome->new->from_url($url);

A shortcut to use a string or L<Mojo::URL> to set the arguments for this class (see also L</new>).

The scheme, host, and port portions set the L</target> indicating where to connect to chrome's DevTools Protocol.

Query parameters are available to control the spawned chrome process.
If given, the C<executable> parameter is used to set the L</executable> otherwise the default is not changed.

All other parameters are interpreted as command line switches and used to set the L</arguments>.
The parameter C<headless> is considered a default and is appended unless the parameter C<headless> or C<no-headless> is explicitly given.
Note that C<no-headless> is not an official parameter but is added here to prevent the default of adding C<headless>.
C<remote_debugging_port> should not be given, pass as the port part of the url instead.

=head2 load_page

  $chrome->load_page($url, sub { my ($chrome, $error) = @_; ... });

Request a page and load the result, evaluating any initial javascript in the process.
This subscribes to L<Page|https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-enable> events and then requests the page with L<Page.navigate|https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-navigate>.
It then invokes the callback when the appropriate L<Page.frameStoppedLoading|https://chromedevtools.github.io/devtools-protocol/tot/Page/#event-frameStoppedLoading> event is caught.

If passed a hash reference this is assumed to the the arguments passed to the C<Page.navigate> method.
Otherwise the value is assumed to the be url to load.
If the url (given either way) is relative, it will be made absolute using the L</base> url.

=head2 new

  my $chrome = Mojo::Chrome->new(%attributes);
  my $chrome = Mojo::Chrome->new(\%attributes);
  my $chrome = Mojo::Chrome->new($url);

Construct a new instance of L<Mojo::Chrome>.
If given a single arugment which is not a hash reference that argument is passed to L</from_url> to create an instance from a url.
Otherwise the usual L<Mojo::Base/new> behavior is followed.

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

=head1 SEE ALSO

=over

=item L<Test::Mojo::Role::Chrome>

=item L<Mojolicious>

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
