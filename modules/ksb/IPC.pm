package ksb::IPC;

# Handles the asynchronous communications needed to perform update and build
# processes at the same time. This can be thought of as a partially-abstract
# class, really you should use IPC::Null (which is fully synchronous) or
# IPC::Pipe, which both fall back to common methods implemented here.

use strict;
use warnings;
use 5.014;
no if $] >= 5.018, 'warnings', 'experimental::smartmatch';

our $VERSION = '0.20';

use ksb::Util; # make_exception, list_has
use ksb::Debug;

# IPC message types
use constant {
    MODULE_SUCCESS  => 1, # Used for a successful src checkout
    MODULE_FAILURE  => 2, # Used for a failed src checkout
    MODULE_SKIPPED  => 3, # Used for a skipped src checkout (i.e. build anyways)
    MODULE_UPTODATE => 4, # Used to skip building a module when had no code updates

    # One of these messages should be the first message placed on the queue.
    ALL_SKIPPED     => 5, # Used to indicate a skipped update process (i.e. build anyways)
    ALL_FAILURE     => 6, # Used to indicate a major update failure (don't build)
    ALL_UPDATING    => 7, # Informational message, feel free to start the build.

    # Used to indicate specifically that a source conflict has occurred.
    MODULE_CONFLICT => 8,

    MODULE_LOGMSG   => 9, # Tagged message should be put to TTY for module.

    MODULE_PERSIST_OPT => 10, # Change to a persistent module option
};

sub new
{
    my $class = shift;
    my $defaultOpts = {
        no_update     => 0,
        updated       => { },
        logged_module => 'global',
        messages      => { }, # Holds log output from update process
    };

    # Must bless a hash ref since subclasses expect it.
    return bless $defaultOpts, $class;
}

# Sends a message to the main/build process that a persistent option for the
# given module name must be changed. For use by processes that do not control
# the persistent option store upon shutdown.
sub notifyPersistentOptionChange
{
    my $self = shift;
    my ($moduleName, $optName, $optValue) = @_;

    $self->sendIPCMessage(ksb::IPC::MODULE_PERSIST_OPT, "$moduleName,$optName,$optValue");
}

sub notifyUpdateSuccess
{
    my $self = shift;
    my ($module, $msg) = @_;

    $self->sendIPCMessage(ksb::IPC::MODULE_SUCCESS, "$module,$msg");
}

# Sets which module messages stored by sendLogMessage are supposed to be
# associated with.
sub setLoggedModule
{
    my ($self, $moduleName) = @_;
    $self->{logged_module} = $moduleName;
}

# Sends a message to be logged by the process holding the TTY.
# The logged message is associated with the module set by setLoggedModule.
sub sendLogMessage
{
    my ($self, $msg) = @_;
    my $loggedModule = $self->{logged_module};

    $self->sendIPCMessage(MODULE_LOGMSG, "$loggedModule,$msg");
}

# Prints the given message out (adjusting to have proper whitespace
# if needed). For use with the log-message forwarding facility.
sub _printLoggedMessage
{
    my $msg = shift;

    $msg = "\t$msg" unless $msg =~ /^\s+/;
    ksb::Debug::print_clr($msg);
}

# Waits for an update for a module with the given name.
# Returns a list containing whether the module was successfully updated,
# and any specific string message (e.g. for module update success you get
# number of files affected)
# Will throw an exception for an IPC failure or if the module should not be
# built.
sub waitForModule
{
    my ($self, $module) = @_;
    assert_isa($module, 'ksb::Module');

    my $moduleName = $module->name();
    my $updated = $self->{'updated'};
    my $messagesRef = $self->{'messages'};
    my $message;

    # Wait for for the initial phase to complete, if it hasn't.
    $self->waitForStreamStart();

    # No update? Just mark as successful
    if ($self->{'no_update'} || !$module->phases()->has('update')) {
        $updated->{$moduleName} = 'success';
        return ('success', 'Skipped');
    }

    while(! defined $updated->{$moduleName}) {
        my $buffer;

        my $ipcType = $self->receiveIPCMessage(\$buffer);
        if (!$ipcType)
        {
            croak_runtime("IPC failure updating $moduleName: $!");
        }

        given ($ipcType) {
            when (ksb::IPC::MODULE_SUCCESS) {
                my ($ipcModuleName, $msg) = split(/,/, $buffer);
                $message = $msg;
                $updated->{$ipcModuleName} = 'success';

            }
            when (ksb::IPC::MODULE_SKIPPED) {
                # The difference between success here and 'skipped' below
                # is that success means we should build even though we
                # didn't perform an update, while 'skipped' means the
                # *build* should be skipped even though there was no
                # failure.
                $message = 'skipped';
                $updated->{$buffer} = 'success';
            }
            when (ksb::IPC::MODULE_CONFLICT) {
                $module->setPersistentOption('conflicts-present', 1);
                $message = 'conflicts present';
                $updated->{$buffer} = 'failed';
            }
            when (ksb::IPC::MODULE_FAILURE) {
                $message = 'update failed';
                $updated->{$buffer} = 'failed';
            }
            when (ksb::IPC::MODULE_UPTODATE) {
                # Properly account for users manually doing --refresh-build or
                # using .refresh-me.
                $message = 'no files affected';
                if ($module->buildSystem()->needsRefreshed())
                {
                    $updated->{$buffer} = 'success';
                    note ("\tNo source update, but g[$module] meets other building criteria.");
                }
                else
                {
                    $updated->{$buffer} = 'skipped';
                }
            }
            when (ksb::IPC::MODULE_PERSIST_OPT) {
                my ($ipcModuleName, $optName, $value) = split(',', $buffer);
                my $ctx = $module->buildContext();
                $ctx->setPersistentOption($ipcModuleName, $optName, $value);
            }
            when (ksb::IPC::MODULE_LOGMSG) {
                my ($ipcModuleName, $logMessage) = split(',', $buffer);

                # Print now if we can (means the user's waiting)
                if ($ipcModuleName ~~ ['global', $moduleName]) {
                    _printLoggedMessage($logMessage);
                }
                else {
                    # Save it for later if we can't print it yet.
                    $messagesRef->{$ipcModuleName} //= [ ];
                    push @{$messagesRef->{$ipcModuleName}}, $logMessage;
                }
            }
            default {
                croak_internal("Unhandled IPC type: $ipcType");
            }
        }
    }

    # Out of while loop, should have a status now.

    # If we have 'global' messages they are probably for the first module and
    # include standard setup messages, etc. Print first and then print module's
    # messages.
    for my $item ('global', $moduleName) {
        for my $msg (@{$messagesRef->{$item}}) {
            _printLoggedMessage($msg);
        }

        delete $messagesRef->{$item};
    }

    return ($updated->{$moduleName}, $message);
}

# Just in case we somehow have messages to display after all modules are
# processed, we have this function to show any available messages near the end
# of the script run.
sub outputPendingLoggedMessages
{
    my $self = shift;
    my $messages = $self->{messages};

    while (my ($module, $logMessages) = each %{$messages}) {
        my @nonEmptyMessages = grep { !!$_ } @{$logMessages};
        if (@nonEmptyMessages) {
            note ("Unhandled messages for module $module:");
            ksb::Debug::print_clr($_) foreach @nonEmptyMessages;
        }
    }

    $self->{messages} = { };
}

# Waits on the IPC connection until one of the ALL_* IPC codes is returned.
# If ksb::IPC::ALL_SKIPPED is returned then the 'no_update' entry will be set in
# $self to flag that you shouldn't wait.
# If ksb::IPC::ALL_FAILURE is returned then an exception will be thrown due to the
# fatal error.
# This method can be called multiple times, but only the first time will
# result in a wait.
sub waitForStreamStart
{
    my $self = shift;
    state $waited = 0;

    return if $waited;

    my $buffer  = '';
    my $ipcType = 0;
    $waited = 1;

    while ($ipcType != ksb::IPC::ALL_UPDATING) {
        $ipcType = $self->receiveIPCMessage(\$buffer);

        if (!$ipcType) {
            croak_internal("IPC Failure waiting for stream start :( $!");
        }
        if ($ipcType == ksb::IPC::ALL_FAILURE)
        {
            croak_runtime("Unable to perform source update for any module:\n\t$buffer");
        }
        elsif ($ipcType == ksb::IPC::ALL_SKIPPED)
        {
            $self->{'no_update'} = 1;
        }
        elsif ($ipcType == ksb::IPC::MODULE_LOGMSG) {
            my ($ipcModuleName, $logMessage) = split(',', $buffer);
            $self->{messages}->{$ipcModuleName} //= [ ];
            push @{$self->{messages}->{$ipcModuleName}}, $logMessage;
        }
        elsif ($ipcType != ksb::IPC::ALL_UPDATING)
        {
            croak_runtime("IPC failure while expecting an update status: Incorrect type: $ipcType");
        }
    }
}

# Sends an IPC message along with some IPC type information.
#
# First parameter is the IPC type to send.
# Second parameter is the actual message.
# All remaining parameters are sent to the object's sendMessage()
#  procedure.
sub sendIPCMessage
{
    my ($self, $ipcType, $msg) = @_;

    my $encodedMsg = pack("l! a*", $ipcType, $msg);
    return $self->sendMessage($encodedMsg);
}

# Static class function to unpack a message.
#
# First parameter is the message.
# Second parameter is a reference to a scalar to store the result in.
#
# Returns the IPC message type.
sub unpackMsg
{
    my ($msg, $outBuffer) = @_;
    my $returnType;

    ($returnType, $$outBuffer) = unpack("l! a*", $msg);

    return $returnType;
}

# Receives an IPC message and decodes it into the message and its
# associated type information.
#
# First parameter is a *reference* to a scalar to hold the message contents.
# All remaining parameters are passed to the underlying receiveMessage()
#  procedure.
#
# Returns the IPC type, or undef on failure.
sub receiveIPCMessage
{
    my $self = shift;
    my $outBuffer = shift;

    my $msg = $self->receiveMessage();

    return ($msg ? unpackMsg($msg, $outBuffer) : undef);
}

# These must be reimplemented.  They must be able to handle scalars without
# any extra frills.
#
# sendMessage should accept one parameter (the message to send) and return
# true on success, or false on failure.  $! should hold the error information
# if false is returned.
sub sendMessage { croak_internal("Unimplemented."); }

# receiveMessage should return a message received from the other side, or
# undef for EOF or error.  On error, $! should be set to hold the error
# information.
sub receiveMessage { croak_internal("Unimplemented."); }

# Should be reimplemented if default does not apply.
sub supportsConcurrency
{
    return 0;
}

# Should be reimplemented if default does not apply.
sub close
{
}

1;
