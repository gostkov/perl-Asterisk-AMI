package Asterisk::AMI;

#Register warnings
use warnings::register;

use strict;
use warnings;

use AnyEvent;
use Digest::MD5;
use Scalar::Util qw/weaken/;
use Carp qw/carp/;

#Duh
use version; our $VERSION = qv(0.2.9_01);

#Create a new object and return it; If required options are missing, returns undef
sub new {
        my ($class, %values) = @_;

        my $self = bless {}, $class;

        #Configure our new object and connect, else return undef
        if ($self->_configure(%values) && $self->_connect()) {
                return $self;
        }

        return;
}

#Sets variables for this object Also checks for minimum settings Returns 1 if everything was set, 0 if options were 
#missing
sub _configure {
        my ($self, %config) = @_;

        #Required settings
        my @required = ( 'username', 'secret' );

        #Defaults
        my %defaults = (        peeraddr => '127.0.0.1',
                                peerport => 5038,
                                authtype => 'md5',
                                events => 'off',
                                maxid => 30000,
                                block => 1,
                                originatehack => 1,
                                timeout => 300
                        );

        #Config Validation + Setting
        while (my ($key, $val) = each(%config)) {
                my $opt = lc($key);
                $self->{config}->{$opt} = $val;
        }


        #Check for required options
        foreach my $req (@required) {
                if (!exists $self->{config}->{$req}) {
                        carp "Must supply a username and secret for connecting to asterisk" if warnings::enabled('Asterisk::AMI');
                        return;
                }
        }

        #Change default port if using ssl
        if ($self->{config}->{ssl}) {
                $defaults{peerport} = 5039;
        }

        #Change defaults if AJAM used
        if ($self->{config}->{ajam}) {
		$defaults{peerport} = '8088';
		$defaults{uri} = '/rawman';
                $defaults{keepalive} = 20;
        }

        #Assign defaults for any missing options
        while (my ($opt, $val) = each(%defaults)) {
                if (!defined $self->{config}->{$opt}) {
                        $self->{config}->{$opt} = $val;
                }
        }

        #Make adjustments for Originate Async bullscrap
        if ($self->{config}->{originatehack}) {
                #Turn on call events, otherwise we wont get the Async response
                if (lc($self->{config}->{events}) eq 'off') {
                        $self->{config}->{events} = 'call';
                        #Fake event type so that we will discard events, else by turning on events our event buffer 
                        #Will just continue to fill up.
                        $self->{config}->{handlers} = {} unless ($self->{config}->{handlers});
                #They already turned events on, just add call types to it, assume they are doing something with events 
                #and don't mess with the handlers
                } elsif (lc($self->{config}->{events}) !~ /on|call/x) {
                        $self->{config}->{events} .= ',call';
                }
        }

        #Initialize the seq number
        $self->{idseq} = 1;

        #Weaken reference for use in anonsub
        weaken($self);

        #Set keepalive
	if ($self->{config}->{keepalive}) {
	        $self->{keepalive} = AE::timer($self->{config}->{keepalive}, $self->{config}->{keepalive}, sub { $self->_send_keepalive });
        }

        return 1;
}

#Handles connection failures (includes login failure);
sub _on_connect_err {
        my ($self, $message) = @_;

        if ($self->{config}->{ajam}) {
                warnings::warnif('Asterisk::AMI', "Failed to connect to asterisk - $self->{config}->{peeraddr}");
        } else {
                warnings::warnif('Asterisk::AMI', "Failed to connect to asterisk - $self->{config}->{peeraddr}:$self->{config}->{peerport}");
        }

        warnings::warnif('Asterisk::AMI', "Error Message: $message");

        #Dispatch all callbacks as if they timed out
        $self->_clear_cbs();

        if (exists $self->{config}->{on_connect_err}) {
                $self->{config}->{on_connect_err}->($self, $message);
        } elsif (exists $self->{config}->{on_error}) {
                $self->{config}->{on_error}->($self, $message);
        }

        $self->{sockerr} = 1;

        $self->destroy();

        return;
}

#Handles other errors on the socket
sub _on_error {
        my ($self, $message) = @_;

        if ($self->{config}->{ajam}) {
                warnings::warnif('Asterisk::AMI', "Received Error on socket - $self->{config}->{peeraddr}");
        } else {
                warnings::warnif('Asterisk::AMI', "Received Error on socket - $self->{config}->{peeraddr}:$self->{config}->{peerport}");
        }

        warnings::warnif('Asterisk::AMI', "Error Message: $message");
        
        #Call all cbs as if they had timed out
        $self->_clear_cbs();

        $self->{config}->{on_error}->($self, $message) if (exists $self->{config}->{on_error});
        
        $self->{sockerr} = 1;

        $self->destroy();

        return;
}

#Handles the remote end disconnecting
sub _on_disconnect {
        my ($self) = @_;

        my $message;

        if ($self->{config}->{ajam}) {
                $message = "Remote end disconnected - $self->{config}->{peeraddr}";
                warnings::warnif('Asterisk::AMI', "Remote Asterisk Server ended connection - $self->{config}->{peeraddr}");
        } else {
                $message = "Remote end disconnected - $self->{config}->{peeraddr}:$self->{config}->{peerport}";
                warnings::warnif('Asterisk::AMI', "Remote Asterisk Server ended connection - $self->{config}->{peeraddr}:$self->{config}->{peerport}");
        }

        #Call all callbacks as if they had timed out
        
        $self->_clear_cbs();

        if (exists $self->{config}->{on_disconnect}) {
                $self->{config}->{on_disconnect}->($self, $message);
        } elsif (exists $self->{config}->{on_error}) {
                $self->{config}->{on_error}->($self, $message);
        }

        $self->{sockerr} = 1;

        $self->destroy();

        return;
}

#What happens if our keep alive times out
sub _on_timeout {
        my ($self, $message) = @_;

        warnings::warnif('Asterisk::AMI', $message);

        if (exists $self->{config}->{on_timeout}) {
                $self->{config}->{on_timeout}->($self, $message);
        } elsif (exists $self->{config}->{on_error}) {
                $self->{config}->{on_error}->($self, $message);
        }

        $self->{sockerr} = 1;

        return;
}

#Connects to the AMI Returns 1 on success, 0 on failure
sub _connect {
        my ($self) = @_;

        #Weaken ref for use in anonysub
        weaken($self);

        #Setup callbacks for the handle
        my %hdl = (     on_connect_error => sub { $self->_on_connect_err($_[1]); },
                        on_error => sub { $self->_on_error($_[2]) },
                        on_eof => sub { $self->_on_disconnect; },
                        on_packets => sub { $self->_handle_packets(@_); });

        #Make connection/create handle
        if ($self->{config}->{ajam}) {
                if (eval { require Asterisk::AMI::AJAM } ) {
                        $hdl{peeraddr} = $self->{config}->{peeraddr};
                        $hdl{peerport} = $self->{config}->{peerport};
                        $hdl{uri} = $self->{config}->{uri};
                        $hdl{username} = $self->{config}->{username};
                        $hdl{secret} = $self->{config}->{secret};
                        $hdl{ssl} = $self->{config}->{ssl};
                        $hdl{use_get} = $self->{config}->{use_get};
                        $self->{handle} = Asterisk::AMI::AJAM->new(%hdl);
                } else {
                        warn "Could not load AJAM support, do you have AnyEvent::HTTP and URI::Escape installed?";
                        return;
                }
        } else {
                if ( eval { require Asterisk::AMI::Manager } ) {
                        #Connect address
                        $hdl{connect} = [$self->{config}->{peeraddr}, $self->{config}->{peerport}];

                        #TLS stuff
                        $hdl{tls} = 'connect' if ($self->{config}->{ssl});
                        #TCP Keepalive
                        $hdl{keepalive} = 1 if ($self->{config}->{tcp_keepalive});

                        $self->{handle} = Asterisk::AMI::Manager->new(%hdl);
                } else {
                        warn "Could not load standard Manager support, do you have AnyEvent::Handle installed?";
                        return;
                }
        }

        #Return login status if blocking
        return $self->_login if ($self->{config}->{block});

        #Queue our login
        $self->_login;

        #Start waiting for events for AJAM only
        if ($self->{config}->{ajam} && $self->{config}->{events} ne 'off') {
		my $timeout = 60;

		if ($self->{config}->{timeout}) {
			$timeout += $self->{config}->{timeout};
		} else {
			$timeout += 5;
		}

                $self->{waitevent} = sub { $self->send_action({ Action => 'WaitEvent', Timeout => 60 }, $self->{waitevent}, $timeout)};
		$self->{waitevent}->();
#                $self->send_action({ Action => 'WaitEvent' }, $self->{waitevent}, 0);
        }
        

        #If we have a handle, SUCCESS!
        if (defined $self->{handle}) {
                return 1;
        }

        return;
}

#Accepts one of more packet from the buffer
#Splits it into multiple packets and into key-value pairs
sub _handle_packets {
        my ($self, $hdl, $buffer) = @_;

        my @actions;
        my @events;

        foreach my $packet (split /\015\012\015\012/ox, $buffer) {
                my %parsed;

                foreach my $line (split /\015\012/ox, $packet) {
                        next unless ($line);
                        #Is this our command output?
                        if ($line =~ s/--END\ COMMAND--$//ox) {
                                $parsed{Complete} = 1;

                                push(@{$parsed{Cmd}},split(/\x20*\x0A/ox, $line));
                        } else {
                                #Regular output, split on :\
                                my ($key, $value) = split /:\ /x, $line, 2;
				$value = undef if ($value eq '');
                                $parsed{$key} = $value;
                        }
                }

                #Dispatch depending on packet type
                if (exists $parsed{ActionID}) {
                        push @actions, \%parsed;
                } elsif (exists $parsed{Event}) {
                        push @events, \%parsed;
                }
        }

        $self->_handle_actions(\@actions) if (@actions);
        $self->_handle_events(\@events) if (@events);        

        return 1;
}

#Handles proccessing and callbacks for action responses
sub _handle_actions {
        my ($self, $packets) = @_;

        foreach my $packet (@{$packets}) {
                #Snag our actionid
                my $actionid = $packet->{ActionID};

                #Discard Unknown ActionIDs
                next unless (exists $self->{permit}->{$actionid});

                #Event responses 
                if (exists $packet->{Event}) {
                        #EventCompleted Event?
                        if (lc($packet->{Event}) =~ /complete/ox) {
                                $self->{rbuf}->{$actionid}->{Complete} = 1;
                        } else {
                                #DBGetResponse and Originate Async Exceptions
                                if ($packet->{Event} eq 'DBGetResponse' || $packet->{Event} eq 'OriginateResponse') {
                                        $self->{rbuf}->{$actionid}->{Complete} = 1;
                                }
                        
                                #To the buffer
                                push(@{$self->{rbuf}->{$actionid}->{Events}}, $packet);
                        }
                #Response packets
                } elsif (exists $packet->{Response}) {
                        #If No indication of future packets, mark as completed
                        if ($packet->{Response} ne 'Follows') {
                                #Rewrite these tests
                                #Originate Async Exception is the first test
                                if (!$self->{rbuf}->{$actionid}->{async} 
                                        && (!exists $packet->{Message} 
						|| ($packet->{Message} !~ /follow/ox && $packet->{Message} ne 'Waiting for Event completed'))) {
                                        $self->{rbuf}->{$actionid}->{Complete} = 1;
                                }
                        } 

                        #Copy the response into the buffer
                        foreach (keys %{$packet}) {
                                #Top Level
                                if ($_ =~ /^(?:Response|Message|ActionID|Privilege|Cmd|Complete)$/ox) {
                                        $self->{rbuf}->{$actionid}->{$_} = $packet->{$_};
                                #Body/Parsed
                                } else {
                                        $self->{rbuf}->{$actionid}->{Body}->{$_} = $packet->{$_};
                                }
                        }
                }

                if ($self->{rbuf}->{$actionid}->{Complete}) {
                        #This aciton is finished do not accept any more packets for it
                        delete $self->{permit}->{$actionid};

                        #Do we really need to check if response is there? was required before EXPECTED?
                        #Determine 'Goodness'
                        if (defined $self->{rbuf}->{$actionid}->{Response}
                                && $self->{rbuf}->{$actionid}->{Response} =~ /^(?:Success|Follows|Goodbye|Events Off|Pong)$/ox) {

                                $self->{rbuf}->{$actionid}->{Success} = 1;
                        }
                        #Do callback and cleanup if callback exists
                        if (defined $self->{cbs}->{$actionid}) {
                                $self->{cbs}->{$actionid}->();
                        }
                }
        }

        return 1;
}

#Handles proccessing and callbacks for 'Event' packets
sub _handle_events {
        my ($self, $events) = @_;

        foreach my $event (@{$events}) {
                #If handlers were configured just dispatch, don't buffer
                if (defined $self->{config}->{handlers}) {
                        if (exists $self->{config}->{handlers}->{$event->{Event}}) {
                                $self->{config}->{handlers}->{$event->{Event}}->($self, $event);
                        } elsif (exists $self->{config}->{handlers}->{default}) {
                                $self->{config}->{handlers}->{default}->($self, $event);
                        }
                } else {
                        #Someone is waiting on this packet, don't bother buffering
                        if (exists $self->{is_waiting}) {
                                $self->{is_waiting}->{cb}->($event);
                                delete $self->{is_waiting};
                        #Save for later
                        } else {
                                push(@{$self->{ebuf}}, $event);
                        }
                }
        }

        return 1;
}

#This is used to provide blocking behavior for calls. It installs callbacks for an action if it is not in the buffer 
#and waits for the response before returning it.
sub _wait_response {
        my ($self, $id, $timeout) = @_;

        #Already got it?
        if ($self->{rbuf}->{$id}->{Complete}) {
                my $resp = $self->{rbuf}->{$id};
		$self->cancel($id);

                return $resp;
        }

        #Don't Have it, wait for it Install some handlers and use a CV to simulate blocking
        my $process = AE::cv;

        my $cb = sub {
                my $response = $self->{rbuf}->{$id};
		$self->cancel($id);

                $process->($response);
        };

        $self->{cbs}->{$id} = $cb;
        $timeout = $self->{config}->{timeout} unless (defined $timeout);

        #Should not need to weaken here because this is a blocking call Only outcomes can be error, timeout, or 
        #complete, all of which will finish the cb and clear the reference weaken($self)

        if ($timeout) {
                #Make sure event loop is up to date in case of sleeps
                AE::now_update;

                $self->{timers}->{$id} = AE::timer $timeout, 0, $cb;
        }

        return $process->recv;
}

#Sends an action to the AMI Accepts an Array Returns the actionid of the action
sub send_action {
        my ($self, $actionhash, $callback, $timeout, $store) = @_;

        #No connection
        return unless ($self->{handle});

        #resets id number
        if ($self->{idseq} > $self->{config}->{maxid}) {
                $self->{idseq} = 1;
        }

        my $id = $self->{idseq}++;

        #Store the Action ID
        $self->{lastid} = $id;

        #Delete anything that might be in the buffer
	$self->cancel($id);

        #Store a copy of initial request
        $self->{rbuf}->{$id}->{Request} = $actionhash;

        my %action;
	my $atype;
	my $async;

        #Create an action out of a hash
        while (my ($key, $value) = each(%{$actionhash})) {

                my $lkey = lc($key);

		if ($lkey eq 'action')  {
			$atype = $value;
                #Exception of Orignate Async
                } elsif ($lkey eq 'async' && ($value == 1 || $value eq 'true')) {
                	$value = 'true';
                        $async = 1;
                #Clean out user ActionIDs
                } elsif ($lkey eq 'actionid') {
                        carp "User supplied ActionID being ignored." if warnings::enabled('Asterisk::AMI');
                        next;
                }

                $action{$key} = $value;
        }

        $action{ActionID} = $id;

	unless ($atype) {
	        delete $self->{rbuf}->{$id};
                carp "No 'Action' key supplied in hasref" if warnings::enabled('Asterisk::AMI');
		return;
	}

        $self->{rbuf}->{$id}->{async} = $async if ($async);

        #If logged in send action
        if ($self->{authed} || lc($atype) =~ /login|challenge/x) {
                $self->{handle}->push_write(\%action);
        #Not logged in buffer till we are
        } else {
                $self->{login_buf}->{$id} = \%action;
        }

        #Initialize default status of response
        $self->{rbuf}->{$id}->{ActionID} = $id;
        $self->{rbuf}->{$id}->{Complete} = 0;
        $self->{rbuf}->{$id}->{Success} = 0;
        $self->{permit}->{$id} = undef;

        #Weaken ref of use in anonsub
        weaken($self);

        #Set default timeout if needed
        $timeout = $self->{config}->{timeout} unless (defined $timeout);

        $callback = $self->{config}->{default_cb} unless (defined $callback);

        #Setup callback
        if (defined $callback) {
                $self->{cbs}->{$id} = sub {
                        my $response = $self->{rbuf}->{$id};
			$self->cancel($id);

                        $callback->($self, $response, $store);
                };

                #Start timer for timeouts
                if ($timeout) {
                        $self->{timers}->{$id} = AE::timer $timeout, 0, $self->{cbs}->{$id};
                }
        } elsif ($self->{config}->{autodrop}) {
                delete $self->{permit}->{$id};
                delete $self->{rbuf}->{$id};
        }

        return $id;
}

#Checks for a response to an action If no actionid is given uses last actionid sent Returns 1 if action success, 0 if 
#failure
sub check_response {
        my ($self, $actionid, $timeout) = @_;

        #Check if an actionid was passed, else us last
        $actionid = $self->{lastid} unless (defined $actionid);

        my $resp = $self->_wait_response($actionid, $timeout);

        if ($resp->{Complete}) {
                return $resp->{Success};
        }

        return;
}

#Returns the Action with all command data and event Actions are hash references 
#If an actionid is specified returns that action, otherwise uses last actionid sent
sub get_response {
        my ($self, $actionid, $timeout) = @_;

        #Check if an actionid was passed, else us last
        $actionid = $self->{lastid} unless (defined $actionid);

        #Wait for the action to complete
        my $resp = $self->_wait_response($actionid, $timeout);
        
        if ($resp->{Complete}) {
                return $resp;
        }

        return;
}

#Sends an action and returns its data or undef if the command failed
sub action {
        my ($self, $action, $timeout) = @_;
        
        #Send action
        my $actionid = $self->send_action($action);
        if (defined $actionid) {
                #Get response
                return $self->get_response($actionid, $timeout);
        }

        return;
}

#Sends an action and returns 1 if it was successful and 0 if it failed
sub simple_action {
        my ($self, $action, $timeout) = @_;

        #Send action
        my $actionid = $self->send_action($action);

        if (defined $actionid) {
                my $resp = $self->_wait_response($actionid, $timeout);
                if ($resp->{Complete}) {
                        return $resp->{Success};
                }
        }

        return;
}

#Calculate md5 response to channel
sub _md5_resp {
        my ($self, $challenge) = @_;

        my $md5 = Digest::MD5->new();

        $md5->add($challenge);
        $md5->add($self->{config}->{secret});

        return $md5->hexdigest;
}

#Logs into the AMI
sub _login {
        my ($self) = @_;

        #Auth challenge
        my %challenge;

        #Timeout to use
        my $timeout;
        $timeout = 5 unless ($self->{config}->{timeout});
        
        #Build login action
        my %action = (  Action => 'login',
                        Username => $self->{config}->{username},
                        Events => $self->{config}->{events} );

        #Actions to take for different authtypes
        if (lc($self->{config}->{authtype}) eq 'md5') {
                #Do a challenge
                %challenge = (  Action => 'Challenge',
                                AuthType => $self->{config}->{authtype});
        } else {
                $action{Secret} = $self->{config}->{secret};
        }

        #Blocking connect
        if ($self->{config}->{block}) {
                return $self->_login_block(\%action, \%challenge, $timeout);
        } else {
                return $self->_login_noblock(\%action, \%challenge, $timeout);
        }

        return;
}

#Checks login responses, prints errors
sub _logged_in {
        my ($self, $login) = @_;

        if ($login->{Success}) {
                #Login was good
                $self->{authed} = 1;

                $self->{config}->{on_connect}->($self) if ($self->{config}->{on_connect});

                #Flush pre-login buffer
                foreach (values %{$self->{login_buf}}) {
                        $self->{handle}->push_write($_);
                }

                delete $self->{login_buf};

                return 1;
        } else {
                #Login failed
                if ($login->{Complete}) {
                        $self->_on_connect_err("Login Failed to Asterisk (bad auth) at $self->{config}->{peeraddr}:$self->{config}->{peerport}");
                } else {
                        $self->_on_connect_err("Login Failed to Asterisk due to timeout at $self->{config}->{peeraddr}:$self->{config}->{peerport}");
                }

                return;
        }

        return;
}

#Blocking Login
sub _login_block {
        my ($self, $action, $challenge, $timeout) = @_;

        my $resp;

        #If a challenge exists do handle it first before the login
        if (%{$challenge}) {
                #Get challenge response
                my $chresp = $self->action($challenge,$timeout);

                if ($chresp->{Success}) {

                        $action->{Key} = $self->_md5_resp($chresp->{Body}->{Challenge}, $self->{config}->{secret});
                        $action->{AuthType} = $self->{config}->{authtype};

                        #Login
                        $resp = $self->action($action, $timeout);
                                                
                  } else {
                        #Challenge Failed
                        if ($chresp->{Complete}) {
                                $self->_on_connect_err("$self->{config}->{authtype} challenge failed");
                        } else {
                                $self->_on_connect_err("Timed out waiting for challenge");
                        }

                        return;
                }
        } else {
                #Plaintext login
                $resp = $self->action($action, $timeout);
        }

        return $self->_logged_in($resp);   
}

#Non-blocking login
sub _login_noblock {
        my ($self, $action, $challenge, $timeout) = @_;

        #Weaken ref for use in anonsub
        weaken($self);

        #Callback for login action
        my $login_cb = sub { $self->_logged_in($_[1]) };

        #Do a md5 challenge
        if (%{$challenge}) {
                #Create callbacks for the challenge
                 my $challenge_cb = sub {
                                if ($_[1]->{Success}) {
                                        my $md5 = Digest::MD5->new();

                                        $md5->add($_[1]->{Body}->{Challenge});
                                        $md5->add($self->{config}->{secret});

                                        $md5 = $md5->hexdigest;

                                        $action->{Key} = $md5;
                                        $action->{AuthType} = $self->{config}->{authtype};

                                        $self->send_action($action, $login_cb, $timeout);
                                                
                                } else {
                                        if ($_[1]->{Complete}) {
                                                $self->_on_connect_err("$self->{config}->{authtype} challenge failed");
                                        } else {
                                                $self->_on_connect_err("Timed out waiting for challenge");
                                        }

                                        return;
                                }
                        };

                #Send challenge
                $self->send_action($challenge, $challenge_cb, $timeout);
        } else {
                #Plaintext login
                $self->send_action($action, $login_cb, $timeout);
        }

        return 1;
}

#Disconnect from the AMI If logged in will first issue a logoff
sub disconnect {
        my ($self) = @_;

        $self->destroy();

        #No socket? No Problem.
        return 1;
}

#Pops the topmost event out of the buffer and returns it Events are hash references
sub get_event {
        my ($self, $timeout) = @_;

        $timeout = $self->{config}->{timeout} unless (defined $timeout);

        unless (defined $self->{ebuf}->[0]) {

                my $process = AE::cv;

                $self->{is_waiting}->{cb} = sub { $process->send($_[0]) };
                $self->{is_waiting}->{timeout} = sub { warnings::warnif('Asterisk::AMI', "Timed out waiting for event"); $process->send(undef); };

                $timeout = $self->{config}->{timeout} unless (defined $timeout);

                if ($timeout) {
                        #Make sure event loop is up to date in case of sleeps
                        AE::now_update;

                        $self->{is_waiting}->{timer} = AE::timer $timeout, 0, $self->{is_waiting}->{timeout};
                }

                return $process->recv;
        }

        return shift @{$self->{ebuf}};
}

#Returns server AMI version
sub amiver {
        my ($self) = @_;
        return $self->{handle}->amiver;
}

#Checks the connection, returns 1 if the connection is good
sub connected {
        my ($self, $timeout) = @_;
        
        if ($self && $self->simple_action({ Action => 'Ping' }, $timeout)) {
                return 1;
        } 

        return 0;
}

#Check whether there was an error on the socket
sub error {
        my ($self) = @_;
        return $self->{sockerr};
}

#Sends a keep alive
sub _send_keepalive {
        my ($self) = @_;
        #Weaken ref for use in anonysub
        weaken($self);
        my $cb = sub { 
                        unless ($_[1]->{Success}) {
                                $self->_on_timeout("Asterisk failed to respond to keepalive - $self->{config}->{peeraddr}:$self->{config}->{peerport}");
                        };
                 };

        my $timeout = $self->{config}->{timeout} || 300;

        my $return = $self->send_action({ Action => 'Ping' }, $cb, $timeout);
        
        return $return;
}

#Calls all callbacks as if they had timed out
#Used when an error has occured on the socket
sub _clear_cbs {
        my ($self) = @_;

        foreach my $callback (values %{$self->{cbs}}) {
                $callback->();
        }

        delete $self->{cbs};

        return 1;
}

sub cancel {
	my ($self, $actionid) = @_;

	$actionid = $self->{lastid} unless (defined $actionid);

	delete $self->{cbs}->{$actionid};
	delete $self->{rbuf}->{$actionid};
	delete $self->{timers}->{$actionid};
	delete $self->{permit}->{$actionid};
	delete $self->{login_buf}->{$actionid};

	#If ajam is enabled make sure the http request is ended
	if ($self->{config}->{ajam}) {
		$self->{handle}->request_cancel($actionid);
	}

	return 1;
}

#Runs the AnyEvent loop
sub loop {
        return AnyEvent->loop;
}

#Return user defined ID
sub id {
        my ($self) = @_;

        return  $self->{config}->{id};
}

#Blocking logoff 
sub _blocking_logoff {
        my ($self) = @_;

}

sub _nonblocking_logoff {
        my ($self) = @_;
        my $timeout;

        $timeout = 300 unless ($self->{config}->{timeout});

        $self->action({ Action => 'Logoff' }, $timeout);
        undef $self->{authed};
}

#Cleans up
sub destroy {
        my ($self) = @_;

        $self->DESTROY;

        bless $self, "Asterisk::AMI::destroyed";

        return 1;
}

#Bye bye
sub DESTROY {
        my ($self) = @_;

        #Logoff
        if (!$self->{sockerr} && $self->{authed} && $self->{handle}) {
                #Blocking logoff
                if ($self->{config}->{block}) {
                        $self->action({ Action => 'Logoff' }, 5);
                        $self->{handle}->destroy();
                #When not blocking give asterisk time to actually logoff before we DC
                } else {
                        #Let the handle stick around on logoff
                        #Hopefully fixes broken pipe issue
                        $self->{handle}->linger_destroy({ Action => 'Logoff', ActionID => $self->{idseq}++ });
                }

                undef $self->{authed};
        }

        #Do our own flushing
        $self->_clear_cbs();

        #Cleanup, remove everything
        %{$self} = ();

        return 1;
}

sub Asterisk::AMI::destroyed::AUTOLOAD {
        #Everything Fails!
        return;
}

1;

__END__

=head1 NAME

Asterisk::AMI - Perl module for interacting with the Asterisk Manager Interface

=head1 VERSION

0.2.4_01

=head1 SYNOPSIS

        use Asterisk::AMI;
        my $astman = Asterisk::AMI->new(PeerAddr => '127.0.0.1',
                                        PeerPort => '5038',
                                        Username => 'admin',
                                        Secret => 'supersecret'
                                );
        
        die "Unable to connect to asterisk" unless ($astman);

        my $action = $astman->({ Action => 'Command',
                                 Command => 'sip show peers'
                                });

=head1 DESCRIPTION

This module provides an interface to the Asterisk Manager Interface. It's goal is to provide a flexible, powerful, and 
reliable way to interact with Asterisk upon which other applications may be built. It utilizes AnyEvent and therefore 
can integrate very easily into event-based applications, but it still provides blocking functions for us with standard 
scripting.

=head2 SSL SUPPORT INFORMATION

For SSL support you will also need the module that AnyEvent::Handle uses for SSL support, which is not a required 
dependency. Currently that module is 'Net::SSLeay' (AnyEvent:Handle version 5.251) but it may change in the future.

=head3 CentOS/Redhat

If the version of Net:SSLeay included in CentOS/Redhat does not work try installing an updated version from CPAN.

=head2 Constructor

=head3 new([ARGS])

Creates a new AMI object which takes the arguments as key-value pairs.

        Basic Options:
        PeerAddr                Remote host address (default 127.0.0.1 or 'http://127.0.0.1:8088/rawman' for AJAM)        <hostname>
        PeerPort                Remote host port (default 5038, or 5039 with ssl)        <service>
        Events                  Enable/Disable Events (default 'off')   'off'|'on'|'system,call,log,verbose,command,agent,user,reporting'
        Username                Username to access the AMI
        Secret                  Secret used to connect to AMI
        AuthType                Authentication type to use for login (default 'MD5')   'MD5'|'plaintext'
        SSL                     Enables/Disables SSL for the connection (default 0, requires Net::SSLeay)  0|1
        Timeout                 Default timeout for all actions in seconds (default 300, 0 = no timeout)

        Advance Options:
        ID                      Allows associating an identifier with this AMI object
        MaxID                   Maximum ActionId, also acts as size of buffer (default 30000)
        TCP_Keepalive           Enables/Disables SO_KEEPALIVE option on the socket (default 0)      0|1
        OriginateHack           Changes settings to allow Async Originates to work (default 1)      0|1

        Event-loop integration options:
        Block                   Enable/Disable blocking connects (default 1)        0|1
        Handlers                Hash reference of Handlers for events        { 'Dial' => \&somesub };
        Keepalive               Interval (in seconds) to periodically send 'Ping' actions to asterisk
        
        Advance Event-loop integration options:
        AutoDrop                Discard responses for actions sent without a callback (default 0)       0|1
        Default_CB              A subroutine to set as the default callback to use for actions.
        on_connect              A subroutine to call after we succesfully connect and login
        on_connect_err          A subroutine to call if we have an error while connecting or during login
        on_error                A subroutine to call when an error occurs on the socket
        on_disconnect           A subroutine to call when the remote end disconnects
        on_timeout              A subroutine to call if our Keepalive times out

        AJAM options:
        AJAM                    Enables the use of AJAM instead of the normal manager tcp connection            0|1
        Use_Get                 Forces the use of the HTTP GET method instead of HTTP POST for AJAM requests    0|1       

        Additional Notes:

        'MaxID' is our our max actionid before we reset the counter.

        'Handlers' accepts a hash reference setting a callback handler for the specified events. They hash keys should match
        the contents of the {Event} key of the event object. The handler should be a subroutine reference that
        will be passed a copy of the AMI object and the event object. The 'default' keyword can be used to set
        a default event handler. If handlers are installed we do not buffer events and instead immediately dispatch them.
        If no handler is specified for an event type and a 'default' was not set the event is discarded.

        'Default_CB' can be used with the built in warn_on_bad, and die_on_bad. Example usage { Default_CB => Asterisk::AMI::warn_on_bad }.

        'on_connect' is a subroutine to call when we have successfully connected and logged into the asterisk manager.
        it will be passed our AMI object.

        'on_connect_err', 'on_error', 'on_disconnect'
        These three specify subroutines to call when errors occur. 'on_connect_err' is specifically for errors that
        occur while connecting, as well as failed logins. If 'on_connect_err' or 'on_disconnect' it is not set,
        but 'on_error' is, 'on_error' will be called. 'on_disconnect' is not reliable, as disconnects seem to get lumped
        under 'on_error' instead. When the subroutine specified for any of theses is called the first argument is a copy
        of our AMI object, and the second is a string containing a message/reason. All three of these are 'fatal', when
        they occur we destroy our buffers and our socket connections.

        'on_timeout' is called when a keep-alive has timed out, not when a normal action has. It is non-'fatal'.
        The subroutine will be called with a copy of our AMI object and a message.

        'OriginateHack' defaults to 1 (on). This essentially enables 'call' events and says 'discard all events
        unless the user has explicitly enabled events' (prevents a memory leak). It does its best not to mess up
        anything you have already set. Without this, if you use 'Async' with an 'Originate' the action will timeout
        or never callback. You don't need this if you are already doing work with events, simply add 'call' events
        to your eventmask. If you are having odd event problems try disabling this.

        AJAM Notes:

        When using AJAM 'PeerAddr' should be the full URL (with port) to the AJAM rawman interface 
        (e.g. 'http://127.0.0.1:8080/asterisk/rawman'). HTTPS is supported.

	Older versions of Asterisk (e.g. 1.4) may not support HTTP posts.

        The default for 'KeepAlive' is set to 20 seconds to prevent authentication from expiring.

        For more AJAM implementation details see Asterisk::AMI::AJAM.

=head2 Disabling Warnings

        If you have warnings enabled this module will emit a number of them on connection errors, deprecated features, etc.
        To disable this but still have all other warnings in perl enabled you can do the following:

                use Asterisk::AMI;
                use warnings;
                no warnings qw(Asterisk::AMI);

        That will enable warnings but disable any warnings from this module.

=head2 Warning - Mixing Event-loops and blocking actions

        For an intro to Event-Based programming please check out the documentation in AnyEvent::Intro.

        If you are running an event loop and use blocking methods (e.g. get_response, check_response, action,
        simple_action, connected, or a blocking connect) the outcome is unspecified. It may work, it may lock everything up, the action may
        work but break something else. I have tested it and behavior seems unpredictable at best and is very
        circumstantial.

        If you are running an event-loop use non-blocking callbacks! It is why they are there!

        However if you do play with blocking methods inside of your loops let me know how it goes.

=head2 Actions

=head3 ActionIDs

This module handles ActionIDs internally and if you supply one in an action it will simply be ignored and overwritten.

=head3 Construction

No matter which method you use to send an action (send_action(), simple_action(), or action()), they all accept 
actions in the same format, which is a hash reference. The only exceptions to this rules are when specifying a 
callback and a callback timeout, which only work with send_action.

To build and send an action you can do the following:

        %action = ( Action => 'Command',
                    Command => 'sip show peers'
                );

        $astman->send_action(\%action);

Alternatively you can also do the following to the same effect:

        $astman->send_action({  Action => 'Command',
                                Command => 'sip show peers'
                                });

Additionally the value of the hash may be an array reference. When an array reference is used, every value in the 
array is append as a different line to the action. For example:

        { Variable => [ 'var1=1', 'var2=2' ] }

        Will become:

        Variable: var1=1
        Variable: var2=2

        When the action is sent.

=head3 Sending and Retrieving

More detailed information on these individual methods is available below

The send_action() method can be used to send an action to the AMI. It will return a positive integer, which is the 
ActionID of the action, on success and will return undef in the event it is unable to send the action.
        
After sending an action you can then get its response in one of two methods.

The method check_response() accepts an actionid and will return 1 if the action was considered successful, 0 if it 
failed and undef if an error occurred or on timeout.

The method get_response() accepts an actionid and will return a Response object (really just a fancy hash) with the 
contents of the Action Response as well as any associated Events it generated. It will return undef if an error 
occurred or on timeout.

All responses and events are buffered, therefor you can issue several send_action()s and then retrieve/check their 
responses out of order without losing any information. In-fact, if you are issuing many actions in series you can get 
much better performance sending them all first and then retrieving them later, rather than waiting for responses 
immediately after issuing an action.

Alternatively you can also use simple_action() and action(). simple_action() combines send_action() and 
check_response(), and therefore returns 1 on success and 0 on failure, and undef on error or timeout. action() 
combines send_action() and get_response(), and therefore returns a Response object or undef.

=head4 Examples

        Send and retrieve and action:
        my $actionid = $astman->send_action({   Action => 'Command',
                                                Command => 'sip show peers'
                                });

        my $response = $astman->get_response($actionid)

        This is equivalent to the above:
        my $response = $astman->action({        Action => 'Command',
                                                Command => 'sip show peers'
                                });

        The following:
        my $actionid1 = $astman->send_action({  Action => 'Command',
                                                Command => 'sip show peers'
                                });

        my $actionid2 = $astman->send_action({  Action => 'Command',
                                                Command => 'sip show peers'
                                });

        my $actionid3 = $astman->send_action({  Action => 'Command',
                                                Command => 'sip show peers'
                                });

        my $response3 = $astman->get_response($actionid3);
        my $response1 = $astman->get_response($actionid1);
        my $response2 = $astman->get_response($actionid2);

        Can be much faster than:
        my $response1 = $astman->action({       Action => 'Command',
                                                Command => 'sip show peers'
                                });
        my $response2 = $astman->action({       Action => 'Command',
                                                Command => 'sip show peers'
                                });
        my $response3 = $astman->action({       Action => 'Command',
                                                Command => 'sip show peers'
                                });

=head3 Originate Examples

        These don't include non-blocking examples, please read the section on 'Callbacks' below for information
        on using non-blocking callbacks and events.

        NOTE: Please read about the 'OriginateHack' option for the constructor above if you plan on using the 'Async'
        option in your Originate command, as it may be required to properly retrieve the response.

        In these examples we are dialing extension '12345' at a sip peer named 'peer' and when the call connects
        we drop the channel into 'some_context' at priority 1 for extension 100.

        Example 1 - A simple non-ASYNC Originate

        my $response = $astman->action({Action => 'Originate',
                                        Channel => 'SIP/peer/12345',
                                        Context => 'some_context',
                                        Exten => 100,
                                        Priority => 1});

        And the contents of respone will look similiar to the following:

        {
                'Message' => 'Originate successfully queued',
                'ActionID' => '3',
                'Succcess' => 1,
                'Complete' => 1,
                'Response' => 'Success'
        };

        Example 2 - Originate with multiple variables
        This will set the channel variables 'var1' and 'var2' to 1 and 2, respectfully.
        The value for the 'Variable' key should be an array reference or an anonymous array in order
        to set multiple variables.

        my $response = $astman->action({Action => 'Originate',
                                        Channel => 'SIP/peer/12345',
                                        Context => 'some_context',
                                        Exten => 100,
                                        Priority => 1,
                                        Variable = [ 'var1=1', 'var2=2' ]});

        Example 3 - An Async Originate
        If your Async Originate never returns please read about the 'OriginateHack' option for the constructor.

        my $response = $astman->action({Action => 'Originate',
                                        Channel => 'SIP/peer/12345',
                                        Context => 'some_context',
                                        Exten => 100,
                                        Priority => 1,
                                        Async => 1});

        And the contents of response will look similiar to the following:

        {
                'Message' => 'Originate successfully queued',
                'events' => [
                        {
                                'Exten' => '100',
                                'CallerID' => '<unknown>',
                                'Event' => 'OriginateResponse',
                                'Privilege' => 'call,all',
                                'Channel' => 'SIP/peer-009c5510',
                                'Context' => 'some_context',
                                'Response' => 'Success',
                                'Reason' => '4',
                                'CallerIDName' => '<unknown>',
                                'Uniqueid' => '1276543236.82',
                                'ActionID' => '3',
                                'CallerIDNum' => '<unknown>'
                        }
                        ],
                'ActionID' => '3',
                'Succcess' => 1,
                'Complete' => 1,
                'Response' => 'Success'
        };

        More Info:
        Check out the voip-info.org page for more information on the Originate action.
        http://www.voip-info.org/wiki/view/Asterisk+Manager+API+Action+Originate

=head3 AJAM Example

        use Asterisk::AMI;
        my $astman = Asterisk::AMI->new(PeerAddr => 'http://my.pbx.example:8080/asterisk/rawman',
                                        AJAM => 1,
                                        Username => 'admin',
                                        Secret => 'supersecret'
                                );
        
        die "Unable to connect to asterisk" unless ($astman);

        my $action = $astman->({ Action => 'Command',
                                 Command => 'sip show peers'
                                });


=head3 Callbacks

        You may also specify a subroutine to callback when using send_action as well as a timeout.

        An example of this would be:
        $astman->send_action({ Action => 'Ping' }, \&somemethod, 7, $somevar);

In this example once the action 'Ping' finishes we will call somemethod() and pass it the a copy of our AMI object, 
the Response Object for the action, and an optional variable $somevar. If a timeout is not specified
it will use the default set. A value of 0 means no timeout. When the timeout is reached somemethod() will be called
and passed a reference to our $astman and the uncompleted Response Object, therefore somemethod() should check the
state of the object. Checking the key {Success} is usually a good indication if the response is useable.

        Anonymous subroutines are also acceptable as demostrated in the examples below:
        my $callback = sub { return };

        $astman->send_action({ Action => 'Ping' }, $callback, 7);

        Or

        $astman->send_action({ Action => 'Ping' }, sub { return }, 7);

        

=head3 Callback Caveats

Callbacks only work if we are processing packets, therefore you must be running an event loop. Alternatively, we run 
mini-event loops for our blocking calls (e.g. action(), get_action()), so in theory if you set callbacks and then 
issue a blocking call those callbacks should also get triggered. However this is an unsupported scenario.

Timeouts are done using timers and they are set as soon as you send the object. Therefore if you send an action with a 
timeout and then monkey around for a long time before getting back to your event loop (to process input) you can time 
out before ever even attempting to receive the response.

        A very contrived example:
        $astman->send_action({ Action => 'Ping' }, \&somemethod, 3);

        sleep(4);

        #Start loop
        $astman->loop;
        #Oh no we never even tried to get the response yet it will still time out

=head2 Passing Variables in an Action Response

Sometimes, when working in an event framework, you want a way to associate/map the response to an action with another 
identifier used in your application. Normally you would have to maintain some sort of separate mapping involving the 
ActionID to accomplish this. This modules provides a generic way to pass any perl scalar (this includes references) 
with your action which is then passed to the callback with the response.

=head3 Passing

The variable to be passed to the callback should be passed as the fourth argument to the send_action() method.

For example to pass a simple scalar value:

        my $vartostore = "Stored";

        $astman->send_action({ Action => 'Ping' }, \&somemethod, undef, $vartostore });

And to pass a reference:

        my @vartostore = ("One", "Two");

        $astman->send_action({ Action => 'Ping' }, \&somemethod, undef,  \@vartostore });

=head3 Retrieving

The passed variable will be available as the third argument to the callback.

To retrieve in a callback:

        my ($astman, $resp, $store) = @_;

        print $store . " was stored\n";

=head2 Responses and Events

        NOTE: Empty fields sent by Asterisk (e.g. 'Account: ' with no value in an event) are set to an undef value. 
	In previous verions you would need to test for '' instead.

=head3 Responses

        Responses are returned as response objects, which are hash references, structured as follows:

        $response->{Response} Response to our packet (Success, Failed, Error, Pong, etc).
                   {ActionID} ActionID of this Response.
                   {Message} Message line of the response.
                   {Events} Array reference containing Event Objects associated with this actionid.
                   {Body} Hash reference of lines we could parse into key->value pairs.
                   {Cmd} Contains command output from 'Action: Command's. It is an array reference.
                   {Complete} 1 if completed, 0 if not (timeout)
                   {Success} 1 if good, 0 if bad. Our best guess if the action succeded (Usually correct).

=head3 Events

        Events are turned into event objects, these are similar to response objects, but their keys vary much more
        depending on the specific event.

        Some common contents are:

        $event->{Event} The type of Event
                {ActionID} Only available if this event was caused by an action

=head3 Event Handlers

        Here is a very simple example of how to use event handlers. Please note that the key for the event handler
        is matched against the event type that asterisk sends. For example if asterisk sends 'Event: Hangup' you use a
        key of 'Hangup' to match it. This works for any event type that asterisk sends.

        my $astman = Asterisk::AMI->new(PeerAddr        =>        '127.0.0.1',
                                        PeerPort        =>        '5038',
                                        Username        =>        'admin',
                                        Secret => 'supersecret',
                                        Events => 'on',
                                        Handlers        => { default => \&do_event,
                                                             Hangup => \&do_hangup };
                                );

        die "Unable to connect to asterisk" unless ($astman);

        sub do_event {
                my ($asterisk, $event) = @_;

                print 'Yeah! Event Type: ' . $event->{Event} . "\r\n";
        }

        sub do_hangup {
                my ($asterisk, $event) = @_;
                print 'Channel ' . $event->{Channel} . ' Hungup because ' . $event->{Cause-txt} . "\r\n";
        }

        #Start some event loop
        someloop;

=head2 How to use in an event-based application

        Getting this module to work with your event based application is really easy so long as you are running an
        event-loop that is supported by AnyEvent. Below is a simple example of how to use this module with your
        preferred event loop. We will use EV as our event loop in this example. I use subroutine references in this
        example, but you could use anonymous subroutines if you want to.

        #Use your preferred loop before our module so that AnyEvent will auto-detect it
        use EV;
        use Asterisk::AMI:

        #Create your connection
        my $astman = Asterisk::AMI->new(PeerAddr => '127.0.0.1',
                                        PeerPort => '5038',
                                        Username => 'admin',
                                        Secret => 'supersecret',
                                        Events => 'on',
                                        Handlers => { default => \&eventhandler }
                                );
        #Alternatively you can set Blocking => 0, and set an on_error sub to catch connection errors
        die "Unable to connect to asterisk" unless ($astman);

        #Define the subroutines for events
        sub eventhandler { my ($ami, $event) = @_; print 'Got Event: ',$event->{Event},"\r\n"; }

        #Define a subroutine for your action callback
        sub actioncb { my ($ami, $response) = @_; print 'Got Action Reponse: ',$response->{Response},"\r\n"; }

        #Send an action
        my $action = $astman->({ Action => 'Ping' }, \&actioncb);

        #Do all of you other eventy stuff here, or before all this stuff, whichever ..............

        #Start our loop
        EV::loop



        That's it, the EV loop will allow us to process input from asterisk. Once the action completes it will
        call the callback, and any events will be dispatched to eventhandler(). As you can see it is fairly
        straight-forward. Most of the work will be in creating subroutines to be called for various events and
        actions that you plan to use.

=head2 Methods

send_action ( ACTION, [ [ CALLBACK ], [ TIMEOUT ], [ USERDATA ] ] )

        Sends the action to asterisk, where ACTION is a hash reference. If no errors occurred while sending it returns
        the ActionID for the action, which is a positive integer above 0. If it encounters an error it will return undef.
        CALLBACK is optional and should be a subroutine reference or any anonymous subroutine. TIMEOUT is optional and
        only has an affect if a CALLBACK is specified. USERDATA is optional and is a perl variable that will be passed to
        the CALLBACK in addition to the response.

        The use of the CALLBACK and TIMEOUT keys in the ACTION has been deprecated. 
        
check_response( [ ACTIONID ], [ TIMEOUT ] )

        Returns 1 if the action was considered successful, 0 if it failed, or undef on timeout or error. If no ACTIONID
        is specified the ACTIONID of the last action sent will be used. If no TIMEOUT is given it blocks, reading in
        packets until the action completes. This will remove a response from the buffer.

get_response ( [ ACTIONID ], [ TIMEOUT ] )

        Returns the response object for the action. Returns undef on error or timeout.
        If no ACTIONID is specified the ACTIONID of the last action sent will be used. If no TIMEOUT is given it
        blocks, reading in packets until the action completes. This will remove the response from the buffer.

action ( ACTION [, TIMEOUT ] )

        Sends the action and returns the response object for the action. Returns undef on error or timeout.
        If no ACTIONID is specified the ACTIONID of the last action sent will be used.
        If no TIMEOUT is given it blocks, reading in packets until the action completes. This will remove the
        response from the buffer.

simple_action ( ACTION [, TIMEOUT ] )

        Sends the action and returns 1 if the action was considered successful, 0 if it failed, or undef on error
        and timeout. If no ACTIONID is specified the ACTIONID of the last action sent will be used. If no TIMEOUT is
        given it blocks, reading in packets until the action completes. This will remove the response from the buffer.

cancel ( [ ACTIONID ] )

	Cancels the last action. Removes all callbacks (without fireing them), timers and buffers for the specified ACTIONID or
	the last action sent. Also disregards any further response from Asterisk for that ActionID. In the case of using
	AJAM also attempts to cancel the HTTP request.

	Always returns 1.	 

id () 

        Returns the ID set in the constuctor or undef if no ID was set.

disconnect ()

        Logoff and disconnects from the AMI. Returns 1 on success and 0 if any errors were encountered.

get_event ( [ TIMEOUT ] )

        This returns the first event object in the buffer, or if no events are in the buffer it reads in packets
        waiting for an event. It will return undef if an error occurs.
        If no TIMEOUT is given it blocks, reading in packets until an event arrives.

amiver ()

        Returns the version of the Asterisk Manager Interface we are connected to. Undef until the connection is made
        (important if you have Blocking => 0).

warn_on_bad ()

        Returns a subroutine reference suitable to use with the Default_CB constructor option or as a callback for an
        action. The returned subroutine generate a warning when an action has failed.

die_on_bad ()

        Returns a subroutine reference suitable to use with the Default_CB constructor option or as a callback for an
        action. The returned subroutine will cause the program to die if an action has failed.

connected ( [ TIMEOUT ] )

        This checks the connection to the AMI to ensure it is still functional. It checks at the socket layer and
        also sends a 'PING' to the AMI to ensure it is still responding. If no TIMEOUT is given this will block
        waiting for a response.

        Returns 1 if the connection is good, 0 if it is not.

error ()

        Returns 1 if there are currently errors on the socket, 0 if everything is ok.

destroy ()

        Destroys the contents of all buffers and removes any current callbacks that are set. Mostly used internally.
        Useful if you want to ensure that our IO handle watcher gets removed.

loop ()

        Starts an eventloop via AnyEvent.

=head1 See Also

AnyEvent, Asterisk::AMI::Common

=head1 AUTHOR

Ryan Bullock (rrb3942@gmail.com)

=head1 BUG REPORTING AND FEEDBACK

Please report any bugs or errors to our github issue tracker at http://github.com/rrb3942/perl-Asterisk-AMI/issues or 
the cpan request tracker at https://rt.cpan.org/Public/Bug/Report.html?Queue=perl-Asterisk-AMI

=head1 LICENSE

Copyright (C) 2010 by Ryan Bullock (rrb3942@gmail.com)

This module is free software.  You can redistribute it and/or modify it under the terms of the Artistic License 2.0.

This program is distributed in the hope that it will be useful, but without any warranty; without even the implied 
warranty of merchantability or fitness for a particular purpose.

=cut
