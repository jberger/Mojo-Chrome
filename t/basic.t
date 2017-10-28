use Mojolicious::Lite;

any '/' => 'main';

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
)->tap(on => error => sub{ fail $_[1] })->wait;

is $result, 'Goodbye', 'correct updated result';

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

