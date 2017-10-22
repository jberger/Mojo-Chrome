use Mojolicious::Lite;

any '/' => 'main';

use Test::More;
use Test::Mojo;

my $t = Test::Mojo->with_roles('+Chrome')->new;
my $url = $t->ua->server->nb_url;

$t->chrome_load_ok($url)
  ->chrome_evaluate_ok(q!document.getElementsByTagName('p')[0].innerHTML!)
  ->chrome_result_is('Goodbye');

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


