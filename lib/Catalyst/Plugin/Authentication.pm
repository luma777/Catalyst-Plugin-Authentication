#!/usr/bin/perl

package Catalyst::Plugin::Authentication;

use base qw/Class::Accessor::Fast Class::Data::Inheritable/;

BEGIN {
    __PACKAGE__->mk_accessors(qw/_user/);
    __PACKAGE__->mk_classdata($_) for qw/_auth_realms/;
}

use strict;
use warnings;

use Tie::RefHash;
use Class::Inspector;

# this optimization breaks under Template::Toolkit
# use user_exists instead
#BEGIN {
#	require constant;
#	constant->import(have_want => eval { require Want });
#}

our $VERSION = "0.10";

sub set_authenticated {
    my ( $c, $user, $realmname ) = @_;

    $c->user($user);
    $c->request->{user} = $user;    # compatibility kludge

    if (!$realmname) {
        $realmname = 'default';
    }
    
    if (    $c->isa("Catalyst::Plugin::Session")
        and $c->config->{authentication}{use_session}
        and $user->supports("session") )
    {
        $c->save_user_in_session($user, $realmname);
    }
    $user->_set_auth_realm($realmname);
    
    $c->NEXT::set_authenticated($user, $realmname);
}

sub _should_save_user_in_session {
    my ( $c, $user ) = @_;

    $c->_auth_sessions_supported
    and $c->config->{authentication}{use_session}
    and $user->supports("session");
}

sub _should_load_user_from_session {
    my ( $c, $user ) = @_;

    $c->_auth_sessions_supported
    and $c->config->{authentication}{use_session}
    and $c->session_is_valid;
}

sub _auth_sessions_supported {
    my $c = shift;
    $c->isa("Catalyst::Plugin::Session");
}

sub user {
    my $c = shift;

    if (@_) {
        return $c->_user(@_);
    }

    if ( defined(my $user = $c->_user) ) {
        return $user;
    } else {
        return $c->auth_restore_user;
    }
}

# change this to allow specification of a realm - to verify the user is part of that realm
# in addition to verifying that they exist. 
sub user_exists {
	my $c = shift;
	return defined($c->_user) || defined($c->_user_in_session);
}


sub save_user_in_session {
    my ( $c, $user, $realmname ) = @_;

    $c->session->{__user_realm} = $realmname;
    
    # we want to ask the backend for a user prepared for the session.
    # but older modules split this functionality between the user and the
    # backend.  We try the store first.  If not, we use the old method.
    my $realm = $c->get_auth_realm($realmname);
    if ($realm->{'store'}->can('for_session')) {
        $c->session->{__user} = $realm->{'store'}->for_session($c, $user);
    } else {
        $c->session->{__user} = $user->for_session;
    }
}

sub logout {
    my $c = shift;

    $c->user(undef);

    if (
        $c->isa("Catalyst::Plugin::Session")
        and $c->config->{authentication}{use_session}
        and $c->session_is_valid
    ) {
        delete @{ $c->session }{qw/__user __user_realm/};
    }
    
    $c->NEXT::logout(@_);
}

sub find_user {
    my ( $c, $userinfo, $realmname ) = @_;
    
    $realmname ||= 'default';
    my $realm = $c->get_auth_realm($realmname);
    if ( $realm->{'store'} ) {
        return $realm->{'store'}->find_user($userinfo, $c);
    } else {
        $c->log->debug('find_user: unable to locate a store matching the requested realm');
    }
}


sub _user_in_session {
    my $c = shift;

    return unless $c->_should_load_user_from_session;

    return $c->session->{__user};
}

sub _store_in_session {
    my $c = shift;
    
    # we don't need verification, it's only called if _user_in_session returned something useful

    return $c->session->{__user_store};
}

sub auth_restore_user {
    my ( $c, $frozen_user, $realmname ) = @_;

    $frozen_user ||= $c->_user_in_session;
    return unless defined($frozen_user);

    $realmname  ||= $c->session->{__user_realm};
    return unless $realmname; # FIXME die unless? This is an internal inconsistency

    my $realm = $c->get_auth_realm($realmname);
    $c->_user( my $user = $realm->{'store'}->from_session( $c, $frozen_user ) );
    
    # this sets the realm the user originated in.
    $user->_set_auth_realm($realmname);
    return $user;

}

# we can't actually do our setup in setup because the model has not yet been loaded.  
# So we have to trigger off of setup_finished.  :-(
sub setup {
    my $c = shift;

    $c->_authentication_initialize();
    $c->NEXT::setup(@_);
}

## the actual initialization routine. whee.
sub _authentication_initialize {
    my $c = shift;

    if ($c->_auth_realms) { return };
    
    my $cfg = $c->config->{'authentication'} || {};

    %$cfg = (
        use_session => 1,
        %$cfg,
    );

    my $realmhash = {};
    $c->_auth_realms($realmhash);
    
    ## BACKWARDS COMPATIBILITY - if realm is not defined - then we are probably dealing
    ## with an old-school config.  The only caveat here is that we must add a classname 
    if (exists($cfg->{'realms'})) {
        
        foreach my $realm (keys %{$cfg->{'realms'}}) {
            $c->setup_auth_realm($realm, $cfg->{'realms'}{$realm});
        }

        #  if we have a 'default-realm' in the config hash and we don't already 
        # have a realm called 'default', we point default at the realm specified
        if (exists($cfg->{'default_realm'}) && !$c->get_auth_realm('default')) {
            $c->_set_default_auth_realm($cfg->{'default_realm'});
        }
    } else {
        foreach my $storename (keys %{$cfg->{'stores'}}) {
            my $realmcfg = {
                store => $cfg->{'stores'}{$storename},
            };
            $c->setup_auth_realm($storename, $realmcfg);
        }
    }
    
}


# set up realmname.
sub setup_auth_realm {
    my ($app, $realmname, $config) = @_;
    
    $app->log->debug("Setting up $realmname");
    if (!exists($config->{'store'}{'class'})) {
        Carp::croak "Couldn't setup the authentication realm named '$realmname', no class defined";
    } 
        
    # use the 
    my $storeclass = $config->{'store'}{'class'};
    
    ## follow catalyst class naming - a + prefix means a fully qualified class, otherwise it's
    ## taken to mean C::P::A::Store::(specifiedclass)::Backend
    if ($storeclass !~ /^\+(.*)$/ ) {
        $storeclass = "Catalyst::Plugin::Authentication::Store::${storeclass}::Backend";
    } else {
        $storeclass = $1;
    }
    

    # a little niceness - since most systems seem to use the password credential class, 
    # if no credential class is specified we use password.
    $config->{credential}{class} ||= "Catalyst::Plugin::Authentication::Credential::Password";

    my $credentialclass = $config->{'credential'}{'class'};
    
    ## follow catalyst class naming - a + prefix means a fully qualified class, otherwise it's
    ## taken to mean C::P::A::Credential::(specifiedclass)
    if ($credentialclass !~ /^\+(.*)$/ ) {
        $credentialclass = "Catalyst::Plugin::Authentication::Credential::${credentialclass}";
    } else {
        $credentialclass = $1;
    }
    
    # if we made it here - we have what we need to load the classes;
    Catalyst::Utils::ensure_class_loaded( $credentialclass );
    Catalyst::Utils::ensure_class_loaded( $storeclass );
    
    # BACKWARDS COMPATIBILITY - if the store class does not define find_user, we define it in terms 
    # of get_user and add it to the class.  this is because the auth routines use find_user, 
    # and rely on it being present. (this avoids per-call checks)
    if (!$storeclass->can('find_user')) {
        no strict 'refs';
        *{"${storeclass}::find_user"} = sub {
                                                my ($self, $info) = @_;
                                                my @rest = @{$info->{rest}} if exists($info->{rest});
                                                $self->get_user($info->{id}, @rest);
                                            };
    }
    
    $app->auth_realms->{$realmname}{'store'} = $storeclass->new($config->{'store'}, $app);
    if ($credentialclass->can('new')) {
        $app->auth_realms->{$realmname}{'credential'} = $credentialclass->new($config->{'credential'}, $app);
    } else {
        # if the credential class is not actually a class - has no 'new' operator, we wrap it, 
        # once again - to allow our code to be simple at runtime and allow non-OO packages to function.
        my $wrapperclass = 'Catalyst::Plugin::Authentication::Credential::Wrapper';
        Catalyst::Utils::ensure_class_loaded( $wrapperclass );
        $app->auth_realms->{$realmname}{'credential'} = $wrapperclass->new($config->{'credential'}, $app);
    }
}

sub auth_realms {
    my $self = shift;
    return($self->_auth_realms);
}

sub get_auth_realm {
    my ($app, $realmname) = @_;
    return $app->auth_realms->{$realmname};
}


# Very internal method.  Vital Valuable Urgent, Do not touch on pain of death.
# Using this method just assigns the default realm to be the value associated
# with the realmname provided.  It WILL overwrite any real realm called 'default'
# so can be very confusing if used improperly.  It's used properly already. 
# Translation: don't use it.
sub _set_default_auth_realm {
    my ($app, $realmname) = @_;
    
    if (exists($app->auth_realms->{$realmname})) {
        $app->auth_realms->{'default'} = $app->auth_realms->{$realmname};
    }
    return $app->get_auth_realm('default');
}

sub authenticate {
    my ($app, $userinfo, $realmname) = @_;
    
    if (!$realmname) {
        $realmname = 'default';
    }
        
    my $realm = $app->get_auth_realm($realmname);
    
    if ($realm && exists($realm->{'credential'})) {
        my $user = $realm->{'credential'}->authenticate($app, $realm->{store}, $userinfo);
        if ($user) {
            $app->set_authenticated($user, $realmname);
            return $user;
        }
    } else {
        $app->log->debug("The realm requested, '$realmname' does not exist," .
                         " or there is no credential associated with it.")
    }
    return undef;
}

## BACKWARDS COMPATIBILITY  -- Warning:  Here be monsters!
#
# What follows are backwards compatibility routines - for use with Stores and Credentials
# that have not been updated to work with C::P::Authentication v0.10.  
# These are here so as to not break people's existing installations, but will go away
# in a future version.
#
# The old style of configuration only supports a single store, as each store module
# sets itself as the default store upon being loaded.  This is the only supported 
# 'compatibility' mode.  
#

sub get_user {
    my ( $c, $uid, @rest ) = @_;

    return $c->find_user( {'id' => $uid, 'rest'=>\@rest }, 'default' );
}


## this should only be called when using old-style authentication plugins.  IF this gets
## called in a new-style config - it will OVERWRITE the store of your default realm.  Don't do it.
## also - this is a partial setup - because no credential is instantiated... in other words it ONLY
## works with old-style auth plugins and C::P::Authentication in compatibility mode.  Trying to combine
## this with a realm-type config will probably crash your app.
sub default_auth_store {
    my $self = shift;

    if ( my $new = shift ) {
        $self->auth_realms->{'default'}{'store'} = $new;
        my $storeclass = ref($new);
        
        # BACKWARDS COMPATIBILITY - if the store class does not define find_user, we define it in terms 
        # of get_user and add it to the class.  this is because the auth routines use find_user, 
        # and rely on it being present. (this avoids per-call checks)
        if (!$storeclass->can('find_user')) {
            no strict 'refs';
            *{"${storeclass}::find_user"} = sub {
                                                    my ($self, $info) = @_;
                                                    my @rest = @{$info->{rest}} if exists($info->{rest});
                                                    $self->get_user($info->{id}, @rest);
                                                };
        }
    }

    return $self->get_auth_realm('default')->{'store'};
}

## BACKWARDS COMPATIBILITY
## this only ever returns a hash containing 'default' - as that is the only
## supported mode of calling this.
sub auth_store_names {
    my $self = shift;

    my %hash = (  $self->get_auth_realm('default')->{'store'} => 'default' );
}

sub get_auth_store {
    my ( $self, $name ) = @_;
    
    if ($name ne 'default') {
        Carp::croak "get_auth_store called on non-default realm '$name'. Only default supported in compatibility mode";        
    } else {
        $self->default_auth_store();
    }
}

sub get_auth_store_name {
    my ( $self, $store ) = @_;
    return 'default';
}

# sub auth_stores is only used internally - here for completeness
sub auth_stores {
    my $self = shift;

    my %hash = ( 'default' => $self->get_auth_realm('default')->{'store'});
}

__PACKAGE__;

__END__

=pod

=head1 NAME

Catalyst::Plugin::Authentication - Infrastructure plugin for the Catalyst
authentication framework.

=head1 SYNOPSIS

    use Catalyst qw/
        Authentication
    /;

    # later on ...
    $c->authenticate({ username => 'myusername', password => 'mypassword' });
    my $age = $c->user->get('age');
    $c->logout;

=head1 DESCRIPTION

The authentication plugin provides generic user support for Catalyst apps. It
is the basis for both authentication (checking the user is who they claim to
be), and authorization (allowing the user to do what the system authorises
them to do).

Using authentication is split into two parts. A Store is used to actually
store the user information, and can store any amount of data related to the
user. Credentials are used to verify users, using information from the store,
given data from the frontend. A Credential and a Store are paired to form a
'Realm'. A Catalyst application using the authentication framework must have
at least one realm, and may have several.

To implement authentication in a Catalyst application you need to add this 
module, and specify at least one realm in the configuration. 

Authentication data can also be stored in a session, if the application 
is using the L<Catalyst::Plugin::Session> module.

B<NOTE> in version 0.10 of this module, the interface to this module changed.
Please see L</COMPATIBILITY ROUTINES> for more information.

=head1 INTRODUCTION

=head2 The Authentication/Authorization Process

Web applications typically need to identify a user - to tell the user apart
from other users. This is usually done in order to display private information
that is only that user's business, or to limit access to the application so
that only certain entities can access certain parts.

This process is split up into several steps. First you ask the user to identify
themselves. At this point you can't be sure that the user is really who they
claim to be.

Then the user tells you who they are, and backs this claim with some piece of
information that only the real user could give you. For example, a password is
a secret that is known to both the user and you. When the user tells you this
password you can assume they're in on the secret and can be trusted (ignore
identity theft for now). Checking the password, or any other proof is called
B<credential verification>.

By this time you know exactly who the user is - the user's identity is
B<authenticated>. This is where this module's job stops, and your application
or other plugins step in.  

The next logical step is B<authorization>, the process of deciding what a user
is (or isn't) allowed to do. For example, say your users are split into two
main groups - regular users and administrators. You want to verify that the
currently logged in user is indeed an administrator before performing the
actions in an administrative part of your application. These decisionsmay be
made within your application code using just the information available after
authentication, or it may be facilitated by a number of plugins.  

=head2 The Components In This Framework

=head3 Realms

Configuration of the Catalyst::Plugin::Authentication framework is done in
terms of realms. In simplest terms, a realm is a pairing of a Credential
verifier and a User storage (Store) backend.

An application can have any number of Realms, each of which operates
independant of the others. Each realm has a name, which is used to identify it
as the target of an authentication request. This name can be anything, such as
'users' or 'members'. One realm must be defined as the default_realm, which is
used when no realm name is specified. More information about configuring
realms is available in the configuration section.

=head3 Credential Verifiers

When user input is transferred to the L<Catalyst> application (typically via
form inputs) the application may pass this information into the authentication
system through the $c->authenticate() method.  From there, it is passed to the
appropriate Credential verifier.

These plugins check the data, and ensure that it really proves the user is who
they claim to be.

=head3 Storage Backends

The authentication data also identifies a user, and the Storage Backend modules
use this data to locate and return a standardized object-oriented
representation of a user.

When a user is retrieved from a store it is not necessarily authenticated.
Credential verifiers accept a set of authentication data and use this
information to retrieve the user from the store they are paired with.

=head3 The Core Plugin

This plugin on its own is the glue, providing realm configuration, session
integration, and other goodness for the other plugins.

=head3 Other Plugins

More layers of plugins can be stacked on top of the authentication code. For
example, L<Catalyst::Plugin::Session::PerUser> provides an abstraction of
browser sessions that is more persistent per users.
L<Catalyst::Plugin::Authorization::Roles> provides an accepted way to separate
and group users into categories, and then check which categories the current
user belongs to.

=head1 EXAMPLE

Let's say we were storing users in a simple perl hash. Users are
verified by supplying a password which is matched within the hash.

This means that our application will begin like this:

    package MyApp;

    use Catalyst qw/
        Authentication
    /;

    __PACKAGE__->config->{authentication} = 
                    {  
                        default_realm => 'members',
                        realms => {
                            members => {
                                credential => {
                                    class => 'Password'
                                },
                                store => {
                                    class => 'Minimal',
                	                users = {
                	                    bob => {
                	                        password => "s00p3r",                	                    
                	                        editor => 'yes',
                	                        roles => [qw/edit delete/],
                	                    },
                	                    william => {
                	                        password => "s3cr3t",
                	                        roles => [qw/comment/],
                	                    }
                	                }	                
                	            }
                	        }
                    	}
                    };
    

This tells the authentication plugin what realms are available, which
credential and store modules are used, and the configuration of each. With
this code loaded, we can now attempt to authenticate users.

To show an example of this, let's create an authentication controller:

    package MyApp::Controller::Auth;

    sub login : Local {
        my ( $self, $c ) = @_;

        if (    my $user = $c->req->param("user")
            and my $password = $c->req->param("password") )
        {
            if ( $c->authenticate( { username => $user, 
                                     password => $password } ) ) {
                $c->res->body( "hello " . $c->user->get("name") );
            } else {
                # login incorrect
            }
        }
        else {
            # invalid form input
        }
    }

This code should be very readable. If all the necessary fields are supplied,
call the L<Catalyst::Plugin::Authentication/authenticate> method in the
controller. If it succeeds the user is logged in.

The credential verifier will attempt to retrieve the user whose details match
the authentication information provided to $c->authenticate(). Once it fetches
the user the password is checked and if it matches the user will be
B<authenticated> and C<< $c->user >> will contain the user object retrieved
from the store.

In the above case, the default realm is checked, but we could just as easily
check an alternate realm. If this were an admin login, for example, we could
authenticate on the admin realm by simply changing the $c->authenticate()
call:

    if ( $c->authenticate( { username => $user, 
                             password => $password }, 'admin' )l ) {
        $c->res->body( "hello " . $c->user->get("name") );
    } ...


Now suppose we want to restrict the ability to edit to a user with 'edit'
in it's roles list.  

The restricted action might look like this:

    sub edit : Local {
        my ( $self, $c ) = @_;

        $c->detach("unauthorized")
          unless $c->user_exists
          and $c->user->get('editor') == 'yes';

        # do something restricted here
    }

This is somewhat similar to role based access control.
L<Catalyst::Plugin::Authentication::Store::Minimal> treats the roles field as
an array of role names. Let's leverage this. Add the role authorization
plugin:

    use Catalyst qw/
        ...
        Authorization::Roles
    /;

    sub edit : Local {
        my ( $self, $c ) = @_;

        $c->detach("unauthorized") unless $c->check_roles("edit");

        # do something restricted here
    }

This is somewhat simpler and will work if you change your store, too, since the
role interface is consistent.

Let's say your app grew, and you now have 10000 users. It's no longer
efficient to maintain a hash of users, so you move this data to a database.
You can accomplish this simply by installing the DBIx::Class Store and
changing your config:

    __PACKAGE__->config->{authentication} = 
                    {  
                        default_realm => 'members',
                        realms => {
                            members => {
                                credential => {
                                    class => 'Password'
                                },
                                store => {
                                    class => 'DBIx::Class',
            	                    user_class => 'MyApp::Users',
            	                    role_column => 'roles'	                
            	                }
                	        }
                    	}
                    };

The authentication system works behind the scenes to load your data from the
new source. The rest of your application is completely unchanged.


=head1 CONFIGURATION

=over 4

    # example
    __PACKAGE__->config->{authentication} = 
                {  
                    default_realm => 'members',
                    realms => {
                        members => {
                            credential => {
                                class => 'Password'
                            },
                            store => {
                                class => 'DBIx::Class',
        	                    user_class => 'MyApp::Users',
        	                    role_column => 'roles'	                
        	                }
            	        },
            	        admins => {
            	            credential => {
            	                class => 'Password'
            	            },
            	            store => {
            	                class => '+MyApp::Authentication::Store::NetAuth',
            	                authserver => '192.168.10.17'
            	            }
            	        }
            	        
                	}
                };

=item use_session

Whether or not to store the user's logged in state in the session, if the
application is also using L<Catalyst::Plugin::Session>. This 
value is set to true per default.

=item default_realm

This defines which realm should be used as when no realm is provided to methods
that require a realm such as authenticate or find_user.

=item realms

This contains the series of realm configurations you want to use for your app.
The only rule here is that there must be at least one.  A realm consists of a
name, which is used to reference the realm, a credential and a store.  

Each realm config contains two hashes, one called 'credential' and one called 
'store', each of which provide configuration details to the respective modules.
The contents of these hashes is specific to the module being used, with the 
exception of the 'class' element, which tells the core Authentication module the
classname to instantiate.  

The 'class' element follows the standard Catalyst mechanism of class
specification. If a class is prefixed with a +, it is assumed to be a complete
class name. Otherwise it is considered to be a portion of the class name. For
credentials, the classname 'B<Password>', for example, is expanded to
Catalyst::Plugin::Authentication::Credential::B<Password>. For stores, the
classname 'B<storename>' is expanded to:
Catalyst::Plugin::Authentication::Store::B<storename>::Backend.


=back


=head1 METHODS

=over 4 

=item authenticate( $userinfo, $realm )

Attempts to authenticate the user using the information in the $userinfo hash
reference using the realm $realm. $realm may be omitted, in which case the
default realm is checked.

=item user

Returns the currently logged in user or undef if there is none.

=item user_exists

Returns true if a user is logged in right now. The difference between
user_exists and user is that user_exists will return true if a user is logged
in, even if it has not been retrieved from the storage backend. If you only
need to know if the user is logged in, depending on the storage mechanism this
can be much more efficient.

=item logout

Logs the user out, Deletes the currently logged in user from $c->user and the session.

=item find_user( $userinfo, $realm )

Fetch a particular users details, matching the provided user info, from the realm 
specified in $realm.

=back

=head1 INTERNAL METHODS

These methods are for Catalyst::Plugin::Authentication B<INTERNAL USE> only.
Please do not use them in your own code, whether application or credential /
store modules. If you do, you will very likely get the nasty shock of having
to fix / rewrite your code when things change. They are documented here only
for reference.

=over 4

=item set_authenticated ( $user, $realmname )

Marks a user as authenticated. This is called from within the authenticate
routine when a credential returns a user. $realmname defaults to 'default'

=item auth_restore_user ( $user, $realmname )

Used to restore a user from the session. In most cases this is called without
arguments to restore the user via the session. Can be called with arguments
when restoring a user from some other method.  Currently not used in this way.

=item save_user_in_session ( $user, $realmname )

Used to save the user in a session. Saves $user in session, marked as
originating in $realmname. Both arguments are required.

=item auth_realms

Returns a hashref containing realmname -> realm instance pairs. Realm
instances contain an instantiated store and credential object as the 'store'
and 'credential' elements, respectively

=item get_auth_realm ( $realmname )

Retrieves the realm instance for the realmname provided.

=item 

=back

=head1 SEE ALSO

This list might not be up to date.

=head2 User Storage Backends

L<Catalyst::Plugin::Authentication::Store::Minimal>,
L<Catalyst::Plugin::Authentication::Store::DBIx::Class>,

=head2 Credential verification

L<Catalyst::Plugin::Authentication::Credential::Password>,
L<Catalyst::Plugin::Authentication::Credential::HTTP>,
L<Catalyst::Plugin::Authentication::Credential::TypeKey>

=head2 Authorization

L<Catalyst::Plugin::Authorization::ACL>,
L<Catalyst::Plugin::Authorization::Roles>

=head2 Internals Documentation

L<Catalyst::Plugin::Authentication::Store>

=head2 Misc

L<Catalyst::Plugin::Session>,
L<Catalyst::Plugin::Session::PerUser>

=head1 DON'T SEE ALSO

This module along with its sub plugins deprecate a great number of other
modules. These include L<Catalyst::Plugin::Authentication::Simple>,
L<Catalyst::Plugin::Authentication::CDBI>.

At the time of writing these plugins have not yet been replaced or updated, but
should be eventually: L<Catalyst::Plugin::Authentication::OpenID>,
L<Catalyst::Plugin::Authentication::LDAP>,
L<Catalyst::Plugin::Authentication::CDBI::Basic>,
L<Catalyst::Plugin::Authentication::Basic::Remote>.


=head1 COMPATIBILITY ROUTINES

In version 0.10 of L<Catalyst::Plugin::Authentication>, the API
changed. For app developers, this change is fairly minor, but for
Credential and Store authors, the changes are significant. 

Please see the documentation in version 0.09 of
Catalyst::Plugin::Authentication for a better understanding of how the old API
functioned.

The items below are still present in the plugin, though using them is
deprecated. They remain only as a transition tool, for those sites which can
not yet be upgraded to use the new system due to local customizations or use
of Credential / Store modules that have not yet been updated to work with the 
new backend API.

These routines should not be used in any application using realms
functionality or any of the methods described above. These are for reference
purposes only.

=over 4

=item login

This method is used to initiate authentication and user retrieval. Technically
this is part of the old Password credential module, included here for
completeness.

=item default_auth_store

Return the store whose name is 'default'.

This is set to C<< $c->config->{authentication}{store} >> if that value exists,
or by using a Store plugin:

    # load the Minimal authentication store.
	use Catalyst qw/Authentication Authentication::Store::Minimal/;

Sets the default store to
L<Catalyst::Plugin::Authentication::Store::Minimal::Backend>.

=item get_auth_store $name

Return the store whose name is $name.

=item get_auth_store_name $store

Return the name of the store $store.

=item auth_stores

A hash keyed by name, with the stores registered in the app.

=item register_auth_stores %stores_by_name

Register stores into the application.

=back



=head1 AUTHORS

Yuval Kogman, C<nothingmuch@woobling.org>

Jess Robinson

David Kamholz

Jay Kuri C<jayk@cpan.org>

=head1 COPYRIGHT & LICENSE

        Copyright (c) 2005 the aforementioned authors. All rights
        reserved. This program is free software; you can redistribute
        it and/or modify it under the same terms as Perl itself.

=cut

