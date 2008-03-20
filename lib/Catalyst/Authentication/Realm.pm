package Catalyst::Authentication::Realm;

use strict;
use warnings;

use base qw/Class::Accessor::Fast/;

BEGIN {
    __PACKAGE__->mk_accessors(qw/store credential name config/);
};

## Add use_session config item to realm.

sub new {
    my ($class, $realmname, $config, $app) = @_;

    my $self = { config => $config };
    bless $self, $class;
    
    $self->name($realmname);
    
    if (!exists($self->config->{'use_session'})) {
        if (exists($app->config->{'Plugin::Authentication'}{'use_session'})) {
            $self->config->{'use_session'} = $app->config->{'Plugin::Authentication'}{'use_session'};
        } else {
            $self->config->{'use_session'} = 1;
        }
    }
    print STDERR "use session is " . $self->config->{'use_session'} . "\n";
    $app->log->debug("Setting up auth realm $realmname") if $app->debug;

    # use the Null store as a default
    if( ! exists $config->{store}{class} ) {
        $config->{store}{class} = '+Catalyst::Authentication::Store::Null';
        $app->log->debug( qq(No Store specified for realm "$realmname", using the Null store.) );
    } 
    my $storeclass = $config->{'store'}{'class'};
    
    ## follow catalyst class naming - a + prefix means a fully qualified class, otherwise it's
    ## taken to mean C::P::A::Store::(specifiedclass)
    if ($storeclass !~ /^\+(.*)$/ ) {
        $storeclass = "Catalyst::Authentication::Store::${storeclass}";
    } else {
        $storeclass = $1;
    }

    # a little niceness - since most systems seem to use the password credential class, 
    # if no credential class is specified we use password.
    $config->{credential}{class} ||= '+Catalyst::Authentication::Credential::Password';

    my $credentialclass = $config->{'credential'}{'class'};
    
    ## follow catalyst class naming - a + prefix means a fully qualified class, otherwise it's
    ## taken to mean C::A::Credential::(specifiedclass)
    if ($credentialclass !~ /^\+(.*)$/ ) {
        $credentialclass = "Catalyst::Authentication::Credential::${credentialclass}";
    } else {
        $credentialclass = $1;
    }
    
    # if we made it here - we have what we need to load the classes
    
    ### BACKWARDS COMPATIBILITY - DEPRECATION WARNING:  
    ###  we must eval the ensure_class_loaded - because we might need to try the old-style
    ###  ::Plugin:: module naming if the standard method fails. 
    
    ## Note to self - catch second exception and bitch in detail?
    
    eval {
        Catalyst::Utils::ensure_class_loaded( $credentialclass );
    };
    
    if ($@) {
        $app->log->warn( qq(Credential class "$credentialclass" not found, trying deprecated ::Plugin:: style naming. ) );
        my $origcredentialclass = $credentialclass;
        $credentialclass =~ s/Catalyst::Authentication/Catalyst::Plugin::Authentication/;

        eval { Catalyst::Utils::ensure_class_loaded( $credentialclass ); };
        if ($@) {
            Carp::croak "Unable to load credential class, " . $origcredentialclass . " OR " . $credentialclass . 
                        " in realm " . $self->name;
        }
    }
    
    eval {
        Catalyst::Utils::ensure_class_loaded( $storeclass );
    };
    
    if ($@) {
        $app->log->warn( qq(Store class "$storeclass" not found, trying deprecated ::Plugin:: style naming. ) );
        my $origstoreclass = $storeclass;
        $storeclass =~ s/Catalyst::Authentication/Catalyst::Plugin::Authentication/;
        eval { Catalyst::Utils::ensure_class_loaded( $storeclass ); };
        if ($@) {
            Carp::croak "Unable to load store class, " . $origstoreclass . " OR " . $storeclass . 
                        " in realm " . $self->name;
        }
    }
    
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
    
    ## a little cruft to stay compatible with some poorly written stores / credentials
    ## we'll remove this soon.
    if ($storeclass->can('new')) {
        $self->store($storeclass->new($config->{'store'}, $app, $self));
    } else {
        $app->log->error("THIS IS DEPRECATED: $storeclass has no new() method - Attempting to use uninstantiated");
        $self->store($storeclass);
    }
    if ($credentialclass->can('new')) {
        $self->credential($credentialclass->new($config->{'credential'}, $app, $self));
    } else {
        $app->log->error("THIS IS DEPRECATED: $credentialclass has no new() method - Attempting to use uninstantiated");
        $self->credential($credentialclass);
    }
    
    return $self;
}

sub find_user {
    my ( $self, $authinfo, $c ) = @_;

    my $res = $self->store->find_user($authinfo, $c);
    
    if (!$res) {
      if ($self->config->{'auto_create_user'} && $self->store->can('auto_create_user') ) {
          $res = $self->store->auto_create_user($authinfo, $c);
      }
    } elsif ($self->config->{'auto_update_user'} && $self->store->can('auto_update_user')) {
        $res = $self->store->auto_update_user($authinfo, $c, $res);
    } 
    
    return $res;
}

sub authenticate {
     my ($self, $c, $authinfo) = @_;

     my $user = $self->credential->authenticate($c, $self, $authinfo);
     if (ref($user)) {
         $c->set_authenticated($user, $self->name);
         return $user;
     } else {
         return undef;
     }
}

sub user_is_restorable {
    my ($self, $c) = @_;
    
    return unless
         $c->isa("Catalyst::Plugin::Session")
         and $self->config->{'use_session'}
         and $c->session_is_valid;

    return $c->session->{__user};
}

sub restore_user {
    my ($self, $c, $frozen_user) = @_;
    
    $frozen_user ||= $self->user_is_restorable($c);
    return unless defined($frozen_user);

    $c->_user( my $user = $self->from_session( $c, $frozen_user ) );
    
    # this sets the realm the user originated in.
    $user->auth_realm($self->name);
    
    return $user;
}

sub persist_user {
    my ($self, $c, $user) = @_;
    
    if (
        $c->isa("Catalyst::Plugin::Session")
        and $self->config->{'use_session'}
        and $user->supports("session") 
    ) {
        $c->session->{__user_realm} = $self->name;
    
        # we want to ask the store for a user prepared for the session.
        # but older modules split this functionality between the user and the
        # store.  We try the store first.  If not, we use the old method.
        if ($self->store->can('for_session')) {
            $c->session->{__user} = $self->store->for_session($c, $user);
        } else {
            $c->session->{__user} = $user->for_session;
        }
    }
    return $user;
}

sub remove_persisted_user {
    my ($self, $c) = @_;
    
    if (
        $c->isa("Catalyst::Plugin::Session")
        and $self->config->{'use_session'}
        and $c->session_is_valid
    ) {
        delete @{ $c->session }{qw/__user __user_realm/};
    }    
}

## backwards compatibility - I don't think many people wrote realms since they
## have only existed for a short time - but just in case.
sub save_user_in_session {
    my ( $self, $c, $user ) = @_;

    return $self->persist_user($c, $user);
}

sub from_session {
    my ($self, $c, $frozen_user) = @_;
    
    return $self->store->from_session($c, $frozen_user);
}


__PACKAGE__;

__END__

=pod

=head1 NAME

Catalyst::Authentication::Realm - Base class for realm objects.

=head1 DESCRIPTION

=head1 CONFIGURATION

=over 4

=item class

By default this class is used by
L<Catalyst::Plugin::Authentication|Catalyst::Plugin::Authentication> for all
realms. The class parameter allows you to choose a different class to use for
this realm. Creating a new Realm class can allow for authentication methods
that fall outside the normal credential/store methodology.

=item auto_create_user

Set this to true if you wish this realm to auto-create user accounts when the
user doesn't exist (most useful for remote authentication schemes).

=item auto_update_user

Set this to true if you wish this realm to auto-update user accounts after
authentication (most useful for remote authentication schemes).

=back

=head1 METHODS

=head2 new( $realmname, $config, $app )

Instantiantes this realm, plus the specified store and credential classes.

=head2 store( )

Returns an instance of the store object for this realm.

=head2 credential( )

Returns an instance of the credential object for this realm.

=head2 find_user( $authinfo, $c )

Retrieves the user given the authentication information provided.  This 
is most often called from the credential.  The default realm class simply
delegates this call the store object.  If enabled, auto-creation and 
auto-updating of users is also handled here.

=head2 authenticate( $c, $authinfo)

Performs the authentication process for the current realm.  The default 
realm class simply delegates this to the credential and sets 
the authenticated user on success.  Returns the authenticated user object;

=head save_user_in_session($c, $user)

Used to save the user in a session. Saves $user in the current session, 
marked as originating in the current realm.  Calls $store->for_session() by 
default.  If for_session is not available in the store class, will attempt
to call $user->for_session().

=head2 from_session($c, $frozenuser )

Triggers restoring of the user from data in the session. The default realm
class simply delegates the call to $store->from_session($c, $frozenuser);

=cut
