package User::SessionRestoring;
use base qw/Catalyst::Plugin::Authentication::User::Hash/;

sub for_session { $_[0]->id }
sub store { $_[0]->{store} }

package AuthSessionTestApp;
use Catalyst qw/
	Session
	Session::Store::Dummy
	Session::State::Cookie

	Authentication
	Authentication::Store::Minimal
	Authentication::Credential::Password
/;

use Test::More;
use Test::Exception;

use Digest::MD5 qw/md5/;

our $users;

sub moose : Local {
	my ( $self, $c ) = @_;

	ok(!$c->sessionid, "no session id yet");
	ok(!$c->user_exists, "no user exists");
	ok(!$c->user, "no user yet");
	ok($c->login( "foo", "s3cr3t" ), "can login with clear");
	is( $c->user, $users->{foo}, "user object is in proper place");
}

sub elk : Local {
	my ( $self, $c ) = @_;

	ok( $c->sessionid, "session ID was restored" );
	ok( $c->user_exists, "user exists" );
	ok( $c->user, "a user was also restored");
	is_deeply( $c->user, $users->{foo}, "restored user is the right one (deep test - store might change identity)" );

	$c->delete_session("bah");
}

sub fluffy_bunny : Local {
	my ( $self, $c ) = @_;

	ok( !$c->sessionid, "no session ID was restored");
	ok( !$c->user, "no user was restored");
}

__PACKAGE__->config->{authentication}{users} = $users = {
	foo => User::SessionRestoring->new(
		id => 'foo',
		password => "s3cr3t",
	),
};

__PACKAGE__->setup;

$users->{foo}{store} = __PACKAGE__->default_auth_store;
