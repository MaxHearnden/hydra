package Hydra::Plugin::EmailNotification;

use strict;
use parent 'Hydra::Plugin';
use feature qw/switch/;
use POSIX qw(strftime);
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP;
use Email::Simple;
use Email::Simple::Creator;
use Sys::Hostname::Long;
use Text::Table;
use File::Slurp;
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub statusDescription {
    my ($buildstatus) = @_;

    my $status = "Failed";
    given ($buildstatus) {
        when (0) { $status = "Success"; }
        when (1) { $status = "Failed with non-zero exit code"; }
        when (2) { $status = "Dependency failed"; }
        when (4) { $status = "Cancelled"; }
    }

   return $status;
}


sub getPrevBuild {
    my ($self, $build) = @_;
    return $self->{db}->resultset('Builds')->search(
        { project => $build->project->name
         , jobset => $build->jobset->name
         , job => $build->job->name
         , system => $build->system
         , finished => 1
         , id => { '<', $build->id }
          , -not => { buildstatus => { -in => [4, 3]} }
        }, { order_by => ["id DESC"], rows => 1 }
        )->single;
}


sub showJobName {
    my ($build) = @_;
    return $build->project->name . ":" . $build->jobset->name . ":" . $build->job->name;
}


sub buildFinished {
    my ($self, $build, $dependents) = @_;

    die unless $build->finished;

    # Figure out to whom to send notification for each build.  For
    # each email address, we send one aggregate email listing only the
    # relevant builds for that address.
    my %addresses;
    foreach my $b ($build, @{$dependents}) {
        my $prevBuild = getPrevBuild($self, $b);
        my $to = $b->jobset->emailoverride ne "" ? $b->jobset->emailoverride : $b->maintainers;

        foreach my $address (split ",", $to) {
            $address = trim $address;

            # Do we want to send mail for this build?
            unless ($ENV{'HYDRA_FORCE_SEND_MAIL'}) {
                next unless $b->jobset->enableemail;

                # If build is cancelled or aborted, do not send email.
                next if $b->buildstatus == 4 || $b->buildstatus == 3;

                # If there is a previous (that is not cancelled or aborted) build
                # with same buildstatus, do not send email.
                next if defined $prevBuild && ($b->buildstatus == $prevBuild->buildstatus);
            }

            $addresses{$address} //= { builds => [] };
            push @{$addresses{$address}->{builds}}, $b;
        }
    }

    # Send an email to each interested address.
    # !!! should use the Template Toolkit here.

    for my $to (keys %addresses) {
        print STDERR "sending mail notification to ", $to, "\n";
        my @builds = @{$addresses{$to}->{builds}};

        my $jobName = showJobName $build;

        my $status = statusDescription($build->buildstatus);

        my $baseurl = hostname_long;
        my $sender = $self->{config}->{'notification_sender'} ||
            (($ENV{'USER'} || "hydra") .  "@" . $baseurl);

        my $selfURI = $self->{config}->{'base_uri'} || "http://localhost:3000";

        sub showTime { my ($x) = @_; return strftime('%Y-%m-%d %H:%M:%S', localtime($x)); }

        my $infoTable = Text::Table->new({ align => "left" }, \ " | ", { align => "left" });
        my @lines = (
            [ "Build ID:", $build->id ],
            [ "Nix name:", $build->nixname ],
            [ "Short description:", $build->description || '(not given)' ],
            [ "Maintainer(s):", $build->maintainers ],
            [ "System:", $build->system ],
            [ "Derivation store path:", $build->drvpath ],
            [ "Output store path:", join(", ", map { $_->path } $build->buildoutputs) ],
            [ "Time added:", showTime $build->timestamp ],
            );
        push @lines, (
            [ "Build started:", showTime $build->starttime ],
            [ "Build finished:", showTime $build->stoptime ],
            [ "Duration:", $build->stoptime - $build->starttime . "s" ],
        ) if $build->starttime;
        $infoTable->load(@lines);

        my $inputsTable = Text::Table->new(
            { title => "Name", align => "left" }, \ " | ",
            { title => "Type", align => "left" }, \ " | ",
            { title => "Value", align => "left" });
        @lines = ();
        foreach my $input ($build->inputs) {
            my $type = $input->type;
            push @lines,
                [ $input->name
                , $input->type
                , ( $input->type eq "build" || $input->type eq "sysbuild")
                  ? $input->dependency->id
                  : ($input->type eq "string" || $input->type eq "boolean")
                  ? $input->value : ($input->uri . ':' . $input->revision)
                ];
        }
        $inputsTable->load(@lines);

        my $loglines = 50;
        my $logtext = logContents($build->drvpath, $loglines);
        $logtext = removeAsciiEscapes($logtext);

        my $prevBuild = getPrevBuild($self, $build);

        my $foo = "\nIn addition, the following jobs failed:\n";
        foreach my $b (@builds) {
            $foo .= "  " . showJobName($b) . " ($selfURI/build/" . $b->id . ")\n";
        }

        my $body = "Hi,\n"
            . "\n"
            . "This is to let you know that Hydra build " . $build->id
            . " of job " . $jobName . " "  . (defined $prevBuild ? "has changed from '" . statusDescription($prevBuild->buildstatus) . "' to '$status'" : "is '$status'" ) .".\n"
            . $foo
            . "\n"
            . "Complete build information can be found on this page: "
            . "$selfURI/build/" . $build->id . "\n"
            . ($build->buildstatus != 0 ? "\nThe last $loglines lines of the build log are shown at the bottom of this email.\n" : "")
            . "\n"
            . "A summary of the build information follows:\n"
            . "\n"
            . $infoTable->body
            . "\n"
            . "The build inputs were:\n"
            . "\n"
            . $inputsTable->title
            . $inputsTable->rule('-', '+')
            . $inputsTable->body
            . "\n"
            . "Regards,\n\nThe Hydra build daemon.\n"
            . ($build->buildstatus != 0 ? "\n---\n$logtext" : "");

        # stripping trailing spaces from lines
        $body =~ s/[\ ]+$//gm;

        my $email = Email::Simple->create(
            header => [
                To      => $to,
                From    => "Hydra Build Daemon <$sender>",
                Subject => "$status: Hydra job $jobName on " . $build->system . ", build " . $build->id,
                'X-Hydra-Instance' => $baseurl,
                'X-Hydra-Project'  => $build->project->name,
                'X-Hydra-Jobset'   => $build->jobset->name,
                'X-Hydra-Job'      => $build->job->name,
                'X-Hydra-System'   => $build->system
            ],
            body => "",
        );
        $email->body_set($body);

        if (defined $ENV{'HYDRA_MAIL_SINK'}) {
            # For testing, redirect all mail to a file.
            write_file($ENV{'HYDRA_MAIL_SINK'}, { append => 1 }, $email->as_string . "\n");
        } else {
            sendmail($email);
        }
    }
}


1;
