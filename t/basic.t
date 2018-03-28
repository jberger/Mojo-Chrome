use Mojolicious::Lite;

any '/' => 'main';
any '/close' => sub {
  my $c = shift;
  $c->inactivity_timeout(0.1);
};

use Test::More;
use Test::Mojo;
use Mojo::Chrome;
use Mojo::IOLoop;

my $t = Test::Mojo->new;
my $url = $t->ua->server->nb_url;
my $chrome = Mojo::Chrome->new;

my $result;
Mojo::IOLoop->delay(
  sub { $chrome->load_page($url, shift->begin) },
  sub {
    my ($delay, $err) = @_;
    die $err if $err;
    $chrome->evaluate(q!document.getElementsByTagName('p')[0].innerHTML!, $delay->begin);
  },
  sub {
    my ($delay, $err, $r) = @_;
    die $err if $err;
    $result = $r;
  },
)->catch(sub{ fail pop })->wait;

is $result, 'Goodbye', 'correct updated result';

my $err;
Mojo::IOLoop->delay(
  sub { $chrome->load_page($url->clone->path('/close'), shift->begin) },
  sub {
    (undef, $err) = @_;
  },
)->catch(sub{ fail pop })->wait;

done_testing;

__DATA__

@@ main.html.ep

<!DOCTYPE html>
<html>
  <head></head>
  <body>
    <p>Hello</p>
    %= javascript begin
      (function(){ document.getElementsByTagName('p')[0].innerHTML = 'Goodbye'; })();
    % end
  </body>
</html>

