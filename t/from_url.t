use Mojo::Base -strict;

use Mojo::Chrome;
use Test::More;

# quick mock default_chrome_executable
no warnings 'redefine';
*Mojo::Chrome::detect_chrome_executable = sub { 'default-chrome' };

my $chrome = Mojo::Chrome->new('https://192.168.0.1:3000');
is $chrome->target->scheme, 'https', 'correct scheme';
is $chrome->target->host, '192.168.0.1', 'correct host';
is $chrome->target->port, '3000', 'correct port';
is $chrome->target->to_string, 'https://192.168.0.1:3000', 'correct overall target';
is $chrome->executable, 'default-chrome', 'executable not set';
is_deeply $chrome->arguments, ['--headless'], 'default arguments as expected';

$chrome = Mojo::Chrome->new('http://127.0.0.1/?headless&disable-gpu');
is_deeply $chrome->arguments, ['--headless', '--disable-gpu'], 'explicit headless with options';
is $chrome->executable, 'default-chrome', 'executable not set';

$chrome = Mojo::Chrome->new('http://127.0.0.1/?disable-gpu');
is_deeply $chrome->arguments, ['--disable-gpu', '--headless'], 'implicit headless with options';
is $chrome->executable, 'default-chrome', 'executable not set';

$chrome = Mojo::Chrome->new('http://127.0.0.1/?disable-gpu&no-headless');
is_deeply $chrome->arguments, ['--disable-gpu'], 'explicit no-headless with options';
is $chrome->executable, 'default-chrome', 'executable not set';

$chrome = Mojo::Chrome->new('http://127.0.0.1/?no-headless');
is_deeply $chrome->arguments, [], 'explicit no-headless with no options';
is $chrome->executable, 'default-chrome', 'executable not set';

$chrome = Mojo::Chrome->new('http://127.0.0.1/?executable=mychrome');
is_deeply $chrome->arguments, ['--headless'], 'no explicit headless with executable';
is $chrome->executable, 'mychrome', 'executable set';

done_testing;

