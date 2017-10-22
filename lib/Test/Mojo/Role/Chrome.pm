package Test::Mojo::Role::Chrome;

use Role::Tiny;
use Mojo::Base -strict;
use Mojo::Chrome;
use Mojo::Util;
use Test2::API ();

__PACKAGE__->Mojo::Base::attr(chrome => sub { Mojo::Chrome->new });
__PACKAGE__->Mojo::Base::attr('chrome_result');

my $_desc = sub { Mojo::Util::encode 'UTF-8', shift || shift };

sub chrome_load_ok {
  my ($self, $navigate, $desc) = @_;
  $desc = $_desc->($desc, 'Chrome navigate to page');
  my $ctx = Test2::API::context();

  my $ok = 0;
  my $err;
  $self->chrome->load_page($navigate, sub {
    (undef, $err) = @_;
    $ok = 1 unless $err;
    Mojo::IOLoop->stop;
  });
  Mojo::IOLoop->start;

  $ctx->diag($err) if $err;
  $ctx->ok($ok, $desc);
  $ctx->release;
  return $self->success($ok);
}

sub chrome_evaluate_ok {
  my ($self, $js, $desc) = @_;
  $desc = $_desc->($desc, 'Chrome evaluate');
  my $ctx = Test2::API::context();

  my $ok = 0;
  my ($err, $result);
  $self->chrome->evaluate($js, sub {
    (undef, $err, $result) = @_;
    $ok = 1 unless $err;
    Mojo::IOLoop->stop;
  });
  Mojo::IOLoop->start;

  $ctx->diag(Mojo::Util::dumper $err) if $err;
  $ctx->ok($ok, $desc);
  $ctx->release;
  return $self->chrome_result($result)->success($ok);
}

sub chrome_result_is {

}

1;

