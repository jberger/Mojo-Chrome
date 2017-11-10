use Mojo::Base -strict;

use Mojo::Chrome;
use Mojo::IOLoop;

binmode(STDOUT, ":utf8");
$|++;

# This is the example from https://medium.com/@lagenar/using-headless-chrome-via-the-websockets-interface-5f498fb67e0f
# of fetching the news headline from Google News. It should not be used as anything but an example.
# It is archived at https://web.archive.org/web/20171020022803/https://medium.com/@lagenar/using-headless-chrome-via-the-websockets-interface-5f498fb67e0f

my $chrome = Mojo::Chrome->new->catch(sub{ pop });
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

