package Mojo::Chrome::Util;

use Mojo::Base -strict;

use IPC::Cmd 'can_run';

sub chrome_executable {
  return $ENV{MOJO_CHROME_EXECUTABLE} if $ENV{MOJO_CHROME_EXECUTABLE};

  my $path = can_run 'google-chrome';
  return $path if $path && -f $path && -x _;

  if ($^O eq 'darwin') {
    $path = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    return $path if $path && -f $path && -x _;
  }

  return undef;
}

1;

