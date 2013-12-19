#!/usr/bin/perl
#
# Transcoder for H264/AAC MP4 Files
#
#  Chris Kennedy (C) 2009
#
$VERSION = "0.0.6";

# import module
use Getopt::Long;
use File::Copy;
use POSIX;

$SIG{INT} = \&catch_signal;
$SIG{HUP} = \&catch_signal;
$SIG{ALRM} = \&catch_signal;

$| = 1;

# Output to Console Handle
open CONSOLE_OUTPUT, '>&', \*STDOUT or die "Can't redirect CONSOLE_OUTPUT to STDOUT: $!";
select CONSOLE_OUTPUT; $| = 1;

# Main Variables
my $ContinueTranscoding = 1;
my ($start) = time;
my ($lasttime) = $start;
my ($result) = 0;
my (@children); # All forking children

# Input Arg Variables
my (@INPUT_FILE, $OUTPUT_FILE);
my $INPUT_PATTERN = ".*\.mpg\$";
my $LOGFILES = 1;
my $KEEPLOGFILES = 0;
my $KEEPSTREAMS = 0;
my $SEPARATE = 1;

my $PRECHECK = 0;
my $DECTHREADS = 1;
my $INPUTFORMAT = "";
my $FPS_DIFF = 0;
my $SYNC = 0;
my $ASYNC = 1;
my $VSYNC = 1;
my $AUDIO_PRELOAD = "0.0";

my $USE_FFMPEG = 0;
my $USE_DECODEAV = 0;
my $USE_MENCODER = 0;
my $AUDIO_USE_WAV = 0;
my $VIDEO_USE_Y4M = 0;
my $AACENC = "";

my $FORMAT = "mp4";
my $VCODEC = "libx264";
my $ACODEC = "libfaac";

# Fifo's
my ($RAW_AUDIO_FIFO) = "";
my ($RAW_VIDEO_FIFO) = "";
my ($COMP_AUDIO_FIFO) = "";
my ($COMP_VIDEO_FIFO) = "";

# Input files
my ($RAW_AUDIO_INPUT) = "";
my ($RAW_VIDEO_INPUT) = "";

# Log Files
my ($OUTPUT_NAME) = "";
my ($MAIN_LOG) = "";
my ($RAW_AUDIO_LOG) = "";
my ($COMP_AUDIO_LOG) = "";
my ($RAW_VIDEO_LOG) = "";
my ($COMP_VIDEO_LOG) = "";
my ($MUXER_LOG) = "";

# Default Codec Settings
default_codec();

# Input Options
$result = get_options();

# Check for bad input options
if (!$result || $help) {
	help();
	exit(0);
}

# Use input codec
read_codec($USE_CODEC);

if ($SHOWCODEC) {
	show_codec();
	exit(0);
}

# Check input args
check_args();

# Setup Executables
setup_exe();

# Setup Verbosity
setup_verb();

# Get output filename base
$OUTPUT_NAME = file_name($OUTPUT_FILE);

# Setup Log file locations
log_file_locations();

# Setup IO Redirection
open STDERR, '>&STDOUT' or die "Can't redirect STDERR to STDOUT: $!";
if ($LOGFILES) {
	open STDOUT, '>&MAIN_LOG' or die "Can't dup stdout to Main Log: $!";
}
select STDOUT; $| = 1;

# Transcode each input file into separate audio/video streams.
# Concatenate if more than one input file.
my ($count, $x) = (0,0);
my (@streams) = ();
my (@stream_delay) = ();
my ($audio_string, $video_string) = ('','');
while($ContinueTranscoding && $INPUT_FILE[$x]) {
	$count++;
	if ($ContinueTranscoding) {
		# Get input file audio/video information
		if (!$RAW_AUDIO_INPUT && !$RAW_VIDEO_INPUT && get_file_info($INPUT_FILE[$x])) {
			$ContinueTranscoding = 0;
			next;
		} elsif ($RAW_AUDIO_INPUT && !-f $RAW_AUDIO_INPUT && !-p $RAW_AUDIO_INPUT) {
			$ContinueTranscoding = 0;
			next;
		} elsif ($RAW_VIDEO_INPUT && !-f $RAW_VIDEO_INPUT && !-p $RAW_VIDEO_INPUT) {
			$ContinueTranscoding = 0;
			next;
		}

		# Setup codec options
		set_codec();

		# Setup x264 command line
		if (setup_x264()) {
			# Failed setup
			$ContinueTranscoding = 0;
			help();
			next
		}

		# Open file handles for decoding input
		if (!$USE_DECODEAV && !$RAW_AUDIO_INPUT && !$RAW_VIDEO_INPUT && open_file($INPUT_FILE[$x])) {
			$ContinueTranscoding = 0;
			next;
		}

		# Setup file locations
		file_locations();

		# Setup Fifo's
		setup_fifo();

        	# Fork and run Stats child processes
		#
        	my $stats_pid = get_new_pid("Status Thread", $OUTPUT_FILE);
        	if ($stats_pid > 0) {
			# Parent Handle File Decoding/Encoding
			if ($SEPARATE) {
				handle_file($INPUT_FILE[$x], $count);
			} else {
				encode_file($INPUT_FILE[$x], $count, $OUTPUT_FILE);
			}
		} elsif ($stats_pid == 0) {
			# Child Status Monitor
			my $ms = 0;
			while($ContinueTranscoding) {
        			select(undef, undef, undef, 0.25);

        			my $num_children = scalar(@children);
				my $cur_status = "";
        			for(my $i = 0; $i < $num_children; $i++) {
                			if (!$children[$i]{'pid'}) {
                        			next;
                			}
					$cur_status.= sprintf("(%d) %s %s |", $children[$i]{'pid'}, $children[$i]{'name'}, $children[$i]{'status'});
        			}

				$ms += 0.25;	
				#if ($VERB >= 0) {
				#	printf(CONSOLE_OUTPUT "\r [%d] %s Waiting for %d ms.\t", $num_children, $cur_status, $ms);
				#}
			}
			exit(0);
		} else {
			# Failed to fork
		}
		kill 1, $stats_pid;
	} else {
		# Failure, bail out
		cleanup();
		exit(1);
	}

	# Close main input file handles
	if (!$USE_DECODEAV && !$RAW_AUDIO_INPUT && !$RAW_VIDEO_INPUT) {
		close_file();
	}
	$x++;
}

# Mux Audio/Video
if ($SEPARATE && $ContinueTranscoding) {
	mux_av($count, $COMP_AUDIO_FIFO, $COMP_VIDEO_FIFO, $audio_string, $video_string, $OUTPUT_FILE);
}

# Clean up fifo's 
cleanup();

# Total Encoding Time
if ($VERB >= 0 && $ContinueTranscoding) {
	print CONSOLE_OUTPUT "\nTook " . (time - $start) . " seconds Total to Encode $OUTPUT_FILE.\n\n";
}

# End of Program
exit(0);


##################
# Misc Functions #
##################

# Rounding Function
sub roundup {
    my $n = shift;
    return(($n == int($n)) ? $n : int($n + 1))
}

# Compute the age of a file in seconds.
sub age_of_file_in_seconds {
        my($path) = shift;
        return (time - ($^T - ((-M $path) * 86400)));
}

# catch_signal
sub catch_signal {
        my $signame = shift;
        $ContinueTranscoding = 0;
        $LastSignal = "SIG$signame";
	if ($VERB > 0) {
        	print CONSOLE_OUTPUT "\nWARNING: Signal " . $LastSignal . " received\n";
	}
        if ($LastSignal eq "SIGALRM") {
		print CONSOLE_OUTPUT "ERROR: timeout transcoding, exiting.\n";
                exit(1);
        }
}

# Open main file handles for decoding input
sub open_file {
	my $file = shift;

	# Open Input File for Audio Decoding
	if (!$NOAUDIO) {
		unless(open(RAWAUDIO, "<$file")) {
			print CONSOLE_OUTPUT "Can't open $file for Audio Decoding $!\n";
			$ContinueTranscoding = 0;
			return 1;
		}
		binmode RAWAUDIO;
	}

	# Open Input File for Video Decoding
	if (!$NOVIDEO) {
		unless(open(RAWVIDEO, "<$file")) {
			print CONSOLE_OUTPUT "Can't open $file for Video Decoding $!\n";
			$ContinueTranscoding = 0;
			return 1;
		}
		binmode RAWVIDEO;
	}
	return 0;
}

# Close main file handles
sub close_file {
	if (!$NOAUDIO) {
		unless(close(RAWAUDIO)) {
			print CONSOLE_OUTPUT "Can't close RAWAUDIO for Audio Decoding $!\n";
		}
	}
	if (!$NOVIDEO) {
		unless(close(RAWVIDEO)) {
			print CONSOLE_OUTPUT  "Can't open RAWVIDEO for Video Decoding $!\n";
		}
	}
} 

# Open/Setup IO for Thread/Fork
sub open_io {
	my $log = shift;
	my $data = shift;
	my $thread = shift;
	my $err = 0;

	if ($LOGFILES) {
              	close(STDOUT);
        	unless (open(STDOUT, ">&$log")) {
			print CONSOLE_OUTPUT "Can't open $thread Handle for $log: $!";
			$err = 1;
		}
	}
        unless(open(STDERR, '>&STDOUT')) {
		print CONSOLE_OUTPUT "Can't redirect STDERR to STDOUT for $thread: $!";
		$err = 1;
	}
	if (-e $data) {
		unless(open(STDIN, "<$data")) {
			print CONSOLE_OUTPUT "Can't read $data for $thread: $!";
			$err = 1;
		}
	} elsif ($data) {
		unless(open(STDIN, "<&$data")) {
			print CONSOLE_OUTPUT "Can't read $data for $thread: $!";
			$err = 1;
		}
	} else {
		unless(open(STDIN, '/dev/null')) {
			print CONSOLE_OUTPUT "Can't reset STDIN for $thread: $!";
			$err = 1;
		}
	}

	return $err;
}

# Close/Teardown IO for Thread/Fork
sub close_io {
	my $thread = shift;
	my $err = 0;

	unless(open(STDIN, '/dev/null')) {
		print CONSOLE_OUTPUT "Can't reset STDIN for $thread: $!";
		$err = 1;
	}
	if ($LOGFILES) {
		unless(open(STDOUT, '<&CONSOLE_OUTPUT')) {
			print CONSOLE_OUTPUT "Can't reset STDOUT for $thread: $!";
			$err = 1;
		}
	}
	return $err;
}

# Show Error from System call failure
sub show_error {
	my $signal = shift;
	my $error = shift;
	my $thread = shift;

	if ($signal == -1) {
       		print CONSOLE_OUTPUT "ERROR: failure to execute $thread $error\n";
	} elsif ($signal & 127) {
       		printf CONSOLE_OUTPUT "ERROR: failure to execute $thread, died with signal %d\n",
			($signal & 127);
	} else {
		printf CONSOLE_OUTPUT "ERROR: failure to execute $thread, exited with value %d\n",
			$signal >> 8;
	}
}

# Show Encoding information and file size
sub show_encoding_info {
	my $file = shift;
	my $action = shift;

	if (!$ContinueTranscoding) {
		return 1;
	}

	# Print out benchmark on time taken to encode
	if (-f $file) {
		if ($VERB >= 0) {
			my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
				$atime,$mtime,$ctime,$blksize,$blocks) = stat($file);
			$size = int($size/1024);
        		print CONSOLE_OUTPUT "\rTook " . (time - $lasttime) . " seconds to $action $file of $size Kbytes.\n\n";

			if ($HINT) {
        			$FORMAT_NICE = "2>&1|tail -7|head -6";
			} else {
        			$FORMAT_NICE = "2>&1|tail -5|head -4";
			}
			my @infolines = `$INFOFFMPEG -i $file $FORMAT_NICE` . "\n";
			foreach (@infolines) {
				$_ =~ s/At least one output file must be specified//g;
				$_ =~ s/\s+$//g;
				$_ =~ s/\n+/\n/g;
				if ($_ ne "" && $_ ne "\n") {
					print CONSOLE_OUTPUT $_;
				}
			}
			print CONSOLE_OUTPUT "\n";
		}
		$lasttime = time;
	} else {
		print CONSOLE_OUTPUT "ERROR: File $file doesn't exist, failed $action.\n";
		return 1;
	}

	return 0;
}

# Encoder File Handler
sub encode_file {
	my $file = shift;
	my $num = shift;
	my $ofile = shift;

	my $enc_pid;
	my (@ENCCMD) = ();

	# Check for delay
	my ($vdelay, $adelay) = ('','');
	if (!$NOVIDEO && $SYNC && $ORIG_VDELAY) {
		if ($SYNC > 1 || $SYNC < -1) {
			$ORIG_VDELAY = $SYNC;
		}
		if ($ORIG_VDELAY =~ /^\-/) {
			# Delay Video
			$ORIG_VDELAY =~ s/^\-//g;
			push(@stream_delay, "video $ORIG_VDELAY");

			$vdelay = "$ORIG_VDELAY";

			if ($VERB >= 0) {
				print CONSOLE_OUTPUT "[$num] Set Video Delay to $ORIG_VDELAY ms.\n";
			}
		} else {
			# Delay Audio
			$ORIG_VDELAY =~ s/^\+//g;
			push(@stream_delay, "audio $ORIG_VDELAY");

			$adelay = "$ORIG_VDELAY";

			if ($VERB >= 0) {
				print CONSOLE_OUTPUT "[$num] Set Audio Delay to $ORIG_VDELAY ms.\n";
			}
		}
	}

	# Send input file to Audio/Video Decoders
	if ($RAW_VIDEO_INPUT && $RAW_AUDIO_INPUT) {
		# Already have decoded raw input
	} elsif ($USE_DECODEAV) {
		decode_av_file($file, $num, $file, $file, $RAW_AUDIO_FIFO, $RAW_VIDEO_FIFO);
	} else {
		decode_file($file, $num, "RAWAUDIO", "RAWVIDEO", $RAW_AUDIO_FIFO, $RAW_VIDEO_FIFO);
	}

	# Show Encoder Settings
	show_enc_settings();

	my @INFILE;
	if (!$USE_OLD_FFMPEG) {
        	push(@INFILE, "-loglevel");
        	push(@INFILE, $LOGLEVEL);
	}
        push(@INFILE, "-v");
        push(@INFILE, $FFVERB);
        #push(@INFILE, "-async");
        #push(@INFILE, $ASYNC);
        #push(@INFILE, "-vsync");
        #push(@INFILE, $VSYNC);
	if ($VCODEC eq "libx264") {
        	push(@INFILE, "-threads");
        	push(@INFILE, $THREADS);
	}
        if ($TIME) {
                push(@INFILE, "-t");
                push(@INFILE, $TIME);
        }
        #my (@IFMT) = split(/\s+/, $INPUTFORMAT);
        #push(@INFILE, @IFMT);

	my $GCMDLINE = "-y";
	my $FCMDLINE = "-f $FORMAT";
	my $ACMDLINE = "-acodec $ACODEC -ar $ARATE" . " -ac $ACHAN -ab $ABRATE" . "k";
	my $VCMDLINE = "-vcodec $VCODEC -b $VBRATE" . "k" . " -qsquish 1 -s $FSIZE -r $OFPS";

	if ($NOAUDIO) {
		$ACMDLINE = "-an";
        	push(@INFILE, "-i");
		push(@INFILE, $RAW_AUDIO_FIFO);
	} elsif ($NOVIDEO) {
		$VCMDLINE = "-vn";
        	push(@INFILE, "-i");
		push(@INFILE, $RAW_VIDEO_FIFO);
	} else {
		my @VIDFMT = split(/\s+/, "-f rawvideo -r $OFPS -vcodec rawvideo -pix_fmt yuv420p -s $FSIZE");
        	push(@INFILE, @VIDFMT);
        	push(@INFILE, "-i");
		push(@INFILE, $RAW_VIDEO_FIFO);
		if ($vdelay) {
        		push(@INFILE, "-itsoffset");
        		push(@INFILE, "00.".$vdelay);
		} 
		my @AUDFMT = split(/\s+/, "-f s16le -acodec pcm_s16le -ar $ARATE -ac $ACHAN");
        	push(@INFILE, @AUDFMT);
        	push(@INFILE, "-i");
		push(@INFILE, $RAW_AUDIO_FIFO);
		if ($adelay) {
        		push(@INFILE, "-itsoffset");
        		push(@INFILE, "00.".$adelay);
		} 
        	push(@INFILE, "-map");
        	push(@INFILE, "0:0");
        	push(@INFILE, "-map");
        	push(@INFILE, "1:0");
	}

	@ENCCMD = split(/\s+/, 
		"@INFILE $GCMDLINE $FCMDLINE $VCMDLINE $ACMDLINE $ofile");

        #
        # Fork and run Encoder child processes
        #
        $encoder_pid = get_new_pid("Encoder", $ofile);
        if ($encoder_pid > 0) {   
        	# Parent of Fork
		#
		if (!$TEST) {
        		# Wait for Audio Encoder pid to exit
       	 		if (wait_for_pid($encoder_pid, "Encoder", $ofile, 0) == 1) {
        			print CONSOLE_OUTPUT "ERROR: Encoder failed to execute\n";
				$ContinueTranscoding = 0;
        		}

			# Check if Video failed
			if (show_encoding_info($ofile, "Encoding")) {
				# Failed
				$ContinueTranscoding = 0;
				return 1;
			}
		}
	} elsif ($encoder_pid == 0) {
        	($EUID, $EGID) = ($UID, $GID); # suid only

		if ($VERB > 1 || $TEST) {
			print CONSOLE_OUTPUT "\n$FFMPEG @ENCCMD\n";
		}

		if (!$TEST) {
			if (open_io("COMP_VIDEO_LOG", "/dev/null", "Encoder")) {
				$ContinueTranscoding = 0;
				exit(1);
			}

                	if (system($FFMPEG, @ENCCMD)) {
				show_error($?, $!, "Encoder");
				close_io("Encoder");
				$ContinueTranscoding = 0;
				exit(1);
			}

			if (close_io("Encoder")) {
				exit(1);
			}

			exit(0);
		} else {
			exit(0);
		}
	} else {
		# Fork Failed
		return 1;
	}

	return 0;
}

# Main file handler
sub handle_file {
	my $file = shift;
	my $num = shift;

	# Check for delay
	my ($vdelay, $adelay) = ('','');
	if (!$NOVIDEO && $SYNC && $ORIG_VDELAY) {
		if ($SYNC > 1 || $SYNC < -1) {
			$ORIG_VDELAY = $SYNC;
		}
		if ($ORIG_VDELAY =~ /^\-/) {
			# Delay Video
			$ORIG_VDELAY =~ s/^\-//g;
			push(@stream_delay, "video $ORIG_VDELAY");

			$vdelay = "-delay 1=$ORIG_VDELAY";

			if ($VERB >= 0) {
				print CONSOLE_OUTPUT "[$num] Set Video Delay to $ORIG_VDELAY ms.\n";
			}
		} else {
			# Delay Audio
			$ORIG_VDELAY =~ s/^\+//g;
			push(@stream_delay, "audio $ORIG_VDELAY");

			$adelay = "-delay 1=$ORIG_VDELAY";

			if ($VERB >= 0) {
				print CONSOLE_OUTPUT "[$num] Set Audio Delay to $ORIG_VDELAY ms.\n";
			}
		}
	}

	# Send input file to Audio/Video Decoders
	if ($RAW_VIDEO_INPUT && $RAW_AUDIO_INPUT) {
		# Already have decoded raw input
	} elsif ($USE_DECODEAV) {
		decode_av_file($file, $num, $file, $file, $RAW_AUDIO_FIFO, $RAW_VIDEO_FIFO);
	} else {
		decode_file($file, $num, "RAWAUDIO", "RAWVIDEO", $RAW_AUDIO_FIFO, $RAW_VIDEO_FIFO);
	}

	# Show Encoder Settings
	show_enc_settings();

	# Run Decode/Encode Transcoder
	if (!$ContinueTranscoding || transcode_to_streams($file, $num, $RAW_AUDIO_FIFO, $RAW_VIDEO_FIFO, $COMP_AUDIO_FIFO, $COMP_VIDEO_FIFO)) {
		print CONSOLE_OUTPUT "ERROR: Failed transcoding $file\n";
		$ContinueTranscoding = 0;
	} elsif (scalar(@INPUT_FILE) > 1) {
		# Multiple Input Files
		if (-f $COMP_AUDIO_FIFO && -f $COMP_VIDEO_FIFO && $ContinueTranscoding) {
			my $audio_tmp;
			if ($NOVIDEO) {
				$audio_tmp = $COMP_AUDIO_FIFO . "_" . $num . ".m4a";
			} else {
				$audio_tmp = $COMP_AUDIO_FIFO . "_" . $num . ".aac";
			}
			my $video_tmp = $COMP_VIDEO_FIFO . "_" . $num . ".264";

			move($COMP_AUDIO_FIFO, $audio_tmp) or print CONSOLE_OUTPUT (qq{failed to move $COMP_AUDIO_FIFO -> $audio_tmp \n});
			move($COMP_VIDEO_FIFO, $video_tmp) or print CONSOLE_OUTPUT (qq{failed to move $COMP_VIDEO_FIFO -> $video_tmp \n});

			push(@streams, $audio_tmp);
			push(@streams, $video_tmp);

			# Build combine command line for MP4BOX
			if ($num == 1) {
				# First set of Audio/Video streams
				$audio_string = "$adelay -add " . $audio_tmp;
				$video_string = "$vdelay -add " . $video_tmp;
			} else {
				# Set of Audio/Video streams
				$audio_string.= " -cat " . $audio_tmp;
				$video_string.= " -cat " . $video_tmp;
			}
		} else {
			if (!$TEST) {
				# Missing output files, must have failed
				print CONSOLE_OUTPUT "ERROR: Failed transcoding $file\n";
				$ContinueTranscoding = 0;
			}
		}
	} else {
		# Missing output files, must have failed
		if ((!$NOAUDIO && !-f $COMP_AUDIO_FIFO) || (!$NOVIDEO && !-f $COMP_VIDEO_FIFO) || !$ContinueTranscoding) {
			if (!$TEST) {
				print CONSOLE_OUTPUT "ERROR: Failed transcoding $file\n";
				$ContinueTranscoding = 0;
			}
		}
	}
	return 0;
}

# Transcode file with decode_av into Audio/Video Streams
sub decode_av_file {
        my $file = shift;
        my $file_num = shift;
        my $ainput = shift;
        my $vinput = shift;
        my $aoutput = shift;
        my $voutput = shift;
	my (@RCMD) = ();
        my (@INFILE) = ();
	my $dec_in_use = "";
	my $raw_pid; 
	my ($DECODER) = ('');

	my ($WIDTH, $HEIGHT) = split(/x/, $FSIZE);

	my $CMD = "-i $vinput ";
	if (!$NOAUDIO) {
		$CMD .= "-a $aoutput -Oc $ACHAN -Or $ARATE ";
	} else {
		$CMD .= "-an ";
	}
	if (!$NOVIDEO) {
		$CMD .= "-v $voutput -Ow $WIDTH -Oh $HEIGHT ";

		if ($OFPS != $ORIG_FRAMERATE) {
			$CMD .= "-Of $OFPS ";
		}
		if ($DEINTERLACE) {
			$CMD .= "-Ol ";
		}
	} else {
		$CMD .= "-vn ";
	}
	$CMD .= "-d -1 -s $VSYNC ";
	if ($TIME) {
		$CMD .= "-t $TIME ";
	}

	$DECODER = $DECODEAV;
	@RCMD = split(/\s+/, $CMD);

        # Fork and run Audio/Video Decoder child processes
	#
        $raw_pid = get_new_pid("A/V Decoder", $aoutput);
        if ($raw_pid > 0) {
        	# Parent of Fork
		#
        	if ($VERB >= 0) {
        		print CONSOLE_OUTPUT "[$file_num] Starting Decode for \"$file\" at " . (time - $start) . " seconds.\n";
        	}
        } elsif ($raw_pid == 0) {
		# Child Fork
                ($EUID, $EGID) = ($UID, $GID); # suid only

                my (@RAWARGS) = ();
                push(@RAWARGS, @RCMD);

                # Audio/Video Decoder
                if ($VERB > 1 || $TEST) {
                        print "\n$DECODER @RAWARGS\n";
                }
                if (!$TEST) {
			if (open_io("RAW_VIDEO_LOG", "/dev/null", "A/V Decoder")) {
				$ContinueTranscoding = 0;
				exit(1);
			}

                        if (system($DECODER, @RAWARGS)) {
				show_error($?, $!, "A/V Decoder");
				close_io("A/V Decoder");
				$ContinueTranscoding = 0;
				exit(1);
			}

			if (close_io("A/V Decoder")) {
				exit(1);
			}

			exit(0);
                } else { 
			exit(0);
		}
        } else {
		# Fork Failed
		return 1;
	}
	return 0;
}

# Transcode file with ffmpeg/mencoder/mplayer into Audio/Video Streams
sub decode_file {
        my $file = shift;
        my $file_num = shift;
        my $ainput = shift;
        my $vinput = shift;
        my $aoutput = shift;
        my $voutput = shift;
	my $afmt = "s16le";
	my (@RACMD) = ();
	my (@RVCMD) = ();
        my (@VINFILE) = ();
        my (@AINFILE) = ();
	my $dec_in_use = "";
	my $raw_audio_pid; 
	my $raw_video_pid;
	my ($ADECODER,$VDECODER) = ('','');

	# Raw Video Command
	if ($USE_FFMPEG && !$VIDEO_USE_Y4M) {
		# FFmpeg Video Decode
		@RVCMD = split(/\s+/, 
			"-y -f rawvideo -r $OFPS -vcodec rawvideo -pix_fmt yuv420p -s $FSIZE $RAWVIDOPTS -an $voutput");
		$VDECODER = $FFMPEG;
		$dec_in_use = "ffmpeg";
	} else {
		my $cmd;
		my $filters = "";
		my ($w, $h) = split(/x/, $FSIZE);

		if ($DEINTERLACE) {
			$filters .= "pp=fd,";
		}

		my $SUBTITLES = "-fontconfig -font 'Sans:style=Bold' -subfont-outline 2 -subfont-text-scale 2.1 -sub-bg-alpha 0 -subfont-blur 0 -sub-bg-color 0 -sid 0";

		if ($VIDEO_USE_Y4M) {
			$cmd.= "-nosound -benchmark -vo yuv4mpeg:file=$voutput ";
			$cmd.= "$SUBTITLES ";
			$cmd.= "-sws $SWS -vf " . $filters . "softskip,scale=$w:$h:0:0 ";

			$VDECODER = $MPLAYER;
		} else {
			# Mencoder Video Decode
			$cmd.= "-audio-preload $AUDIO_PRELOAD $SUBTITLES ";
			$cmd.= "-of rawvideo -ofps $OFPS -nosound ";
			$cmd.= "-ovc raw -sws $SWS -vf " . $filters . "softskip,scale=$w:$h:0:0,format=i420,harddup ";
			$cmd.= "$RAWVIDOPTS -o $voutput";

			$VDECODER = $MENCODER;
		}

		@RVCMD = split(/\s+/, $cmd);
		$dec_in_use = "mencoder";
	}

        # Input File 
	if ($dec_in_use eq "ffmpeg") {
		if (!$USE_OLD_FFMPEG) {
        		push(@VINFILE, "-loglevel");
        		push(@VINFILE, $LOGLEVEL);
		}
        	push(@VINFILE, "-v");
        	push(@VINFILE, $FFVERB);
        	push(@VINFILE, "-async");
       	 	push(@VINFILE, $ASYNC);
        	push(@VINFILE, "-vsync");
        	push(@VINFILE, $VSYNC);
        	push(@VINFILE, "-threads");
        	push(@VINFILE, $DECTHREADS);
		if ($TIME) {
        		push(@VINFILE, "-t");
        		push(@VINFILE, $TIME);
		}
		my (@IFMT) = split(/\s+/, $INPUTFORMAT);
        	push(@VINFILE, @IFMT);
        	push(@VINFILE, "-i");
	} else {
		if ($TIME) {
        		push(@VINFILE, "-endpos");
        		push(@VINFILE, $TIME);
		}
        	push(@VINFILE, "-forceidx");
        	push(@VINFILE, "-noconfig");
        	push(@VINFILE, "all");
        	push(@VINFILE, "-msglevel");
		my @ml = split(/\s+/, "all=". $MEVERB);
        	push(@VINFILE, @ml);
        	push(@VINFILE, "-ignore-start");
        	push(@VINFILE, "-mc");
        	push(@VINFILE, $VSYNC);
		if ($INPUTFORMAT =~ /\-rawvideo/ || $INPUTFORMAT =~ /\-rawaudio/) {
			my (@IFMT) = split(/\s+/, $INPUTFORMAT);
        		push(@VINFILE, @IFMT);
		}
	}
       	push(@VINFILE, "-");

	# Raw PCM or WAV Format
	if ($AUDIO_USE_WAV || $AACENC !~ /faac/) {
		$afmt = "wav";
	}

	# Raw Audio Command
	if ($USE_FFMPEG) {
		@RACMD = split(/\s+/, 
			"-y -f $afmt -acodec pcm_s16le -ar $ARATE -ac $ACHAN -vn $aoutput");
		$ADECODER = $FFMPEG;
		$dec_in_use = "ffmpeg";
	} else {
		my $cmd;

		if ($AUDIO_USE_WAV) {
			$afmt = "lavf -lavfopts format=wav";
		} else {
			$afmt = "rawaudio";
		}

		# Use either Mplayer or Mencoder for raw PCM decoding
		if ($NOVIDEO || $AUDIO_USE_WAV) {
			# WAV format, PCM with MPLAYER
			$cmd.= "-nocorrect-pts -vo null -vc null -ao pcm:fast:file=" . $aoutput;
			$ADECODER = $MPLAYER;
		} else {
			# Mencoder Audio Decode to raw PCM
			$cmd.= "-audio-preload $AUDIO_PRELOAD ";
			$cmd.= "-of $afmt -ovc copy ";
			$cmd.= "-oac pcm -af channels=$ACHAN,lavcresample=$ARATE ";
			$cmd.= "-srate $ARATE -channels $ACHAN -o $aoutput";
			$ADECODER = $MENCODER;
		}

		@RACMD = split(/\s+/, $cmd);
		$dec_in_use = "mencoder";
	}

        # Input File 
	if ($dec_in_use eq "ffmpeg") {
		if (!$USE_OLD_FFMPEG) {
        		push(@AINFILE, "-loglevel");
        		push(@AINFILE, $LOGLEVEL);
		}
        	push(@AINFILE, "-v");
        	push(@AINFILE, $FFVERB);
        	push(@AINFILE, "-async");
       	 	push(@AINFILE, $ASYNC);
        	push(@AINFILE, "-vsync");
        	push(@AINFILE, $VSYNC);
        	push(@AINFILE, "-threads");
        	push(@AINFILE, $DECTHREADS);
		if ($TIME) {
        		push(@AINFILE, "-t");
        		push(@AINFILE, $TIME);
		}
		my (@IFMT) = split(/\s+/, $INPUTFORMAT);
        	push(@AINFILE, @IFMT);
        	push(@AINFILE, "-i");
	} else {
		if ($TIME) {
        		push(@AINFILE, "-endpos");
        		push(@AINFILE, $TIME);
		}
        	push(@AINFILE, "-forceidx");
        	push(@AINFILE, "-noconfig");
        	push(@AINFILE, "all");
        	push(@AINFILE, "-msglevel");
		my @ml = split(/\s+/, "all=". $MEVERB);
        	push(@AINFILE, @ml);
        	push(@AINFILE, "-ignore-start");
        	push(@AINFILE, "-mc");
        	push(@AINFILE, $ASYNC);
		if ($INPUTFORMAT =~ /\-rawvideo/ || $INPUTFORMAT =~ /\-rawaudio/) {
			my (@IFMT) = split(/\s+/, $INPUTFORMAT);
        		push(@AINFILE, @IFMT);
		}
	}
       	push(@AINFILE, "-");

        # Fork and run Audio/Video Decoder child processes
	#
        $raw_audio_pid = get_new_pid("Audio Decoder", $aoutput);
        if ($raw_audio_pid > 0) {
        	# Parent of Fork
		#
                $raw_video_pid = get_new_pid("Video Decoder", $voutput);
                if ($raw_video_pid > 0) {
                        # Parent of Fork
                        # 
			#  Audio/Video Decoders should be running now
        		if ($VERB >= 0) {
        			print CONSOLE_OUTPUT "[$file_num] Starting Decode for \"$file\" at " . (time - $start) . " seconds.\n";
        		}
                } elsif ($raw_video_pid == 0) {
			# Child Fork
			if ($NOVIDEO) {
				exit(0);
			}
                        ($EUID, $EGID) = ($UID, $GID); # suid only

                        my (@RAWVARGS) = ();
                        push(@RAWVARGS, @VINFILE);
                        push(@RAWVARGS, @RVCMD);

                        # Video Decoder
                        if ($VERB > 1 || $TEST) {
                                print "\n$VDECODER @RAWVARGS\n";
                        }
                        if (!$TEST) {
				if (open_io("RAW_VIDEO_LOG", $vinput, "Video Decoder")) {
					$ContinueTranscoding = 0;
					exit(1);
				}

                        	if (system($VDECODER, @RAWVARGS)) {
					show_error($?, $!, "Video Decoder");
					close_io("Video Decoder");
					$ContinueTranscoding = 0;
					exit(1);
				}

				if (close_io("Video Decoder")) {
					exit(1);
				}

				exit(0);
                        } else {
				exit(0);
			}
                } else {
			# Fork Failed
			return 1;
		}
        } elsif ($raw_audio_pid == 0) {
		# Child Fork
		if ($NOAUDIO) {
			exit(0);
		}
                ($EUID, $EGID) = ($UID, $GID); # suid only

                my (@RAWAARGS) = ();
                push(@RAWAARGS, @AINFILE);
                push(@RAWAARGS, @RACMD);

                # Audio Decoder
                if ($VERB > 1 || $TEST) {
                        print "\n$ADECODER @RAWAARGS\n";
                }
                if (!$TEST) {
			if (open_io("RAW_AUDIO_LOG", $ainput, "Audio Decoder")) {
				$ContinueTranscoding = 0;
				exit(1);
			}

                        if (system($ADECODER, @RAWAARGS)) {
				show_error($?, $!, "Audio Decoder");
				close_io("Audio Decoder");
				$ContinueTranscoding = 0;
				exit(1);
			}

			if (close_io("Audio Decoder")) {
				exit(1);
			}

			exit(0);
                } else { 
			exit(0);
		}
        } else {
		# Fork Failed
		return 1;
	}
	return 0;
}

# Transcode file into Audio/Video Streams
sub transcode_to_streams {
        my $file = shift;
        my $file_num = shift;
        my $ainput = shift;
        my $vinput = shift;
        my $aoutput = shift;
        my $voutput = shift;

	# pids
        my $comp_audio_pid;
	my $comp_video_pid;

	my (@CACMD) = ();
	my (@CVCMD) = ();

	# Build command lines
	#

	# Compressed Video Command
	my (@CVCMD) = split(/\s+/, 
		"$X264OPTS -o $voutput - $FSIZE");

	# Compressed Audio Command
	if ($AACENC =~ /faac/) {
		# Use FAAC AAC Encoder
		my $bitrate_line = "-b $ABRATE";
		if ($ABRATE > 160) {
			$bitrate_line = "-q $ABRATE";
		}

		if ($AUDIO_USE_WAV) {
			@CACMD = split(/\s+/, 
				"$bitrate_line --mpeg-vers 4 -o $aoutput -");
		} else {
			@CACMD = split(/\s+/, 
				"-P -R $ARATE -C $ACHAN -X $bitrate_line --mpeg-vers 4 -o $aoutput -");
		}
	} else {
		# Use Nero AAC Encoder
		my $nero_brate = ($ABRATE*1000);
		@CACMD = split(/\s+/, 
			"-br $nero_brate -lc -ignorelength -of $aoutput -if -");
	}

        #
        # Fork and run Audio/Video Encoder child processes
        #
        $comp_audio_pid = get_new_pid("Audio Encoder", $aoutput);
        if ($comp_audio_pid > 0) {   
        	# Parent of Fork
		#
        	$comp_video_pid = get_new_pid("Video Encoder", $voutput);
        	if ($comp_video_pid > 0) {   
        		# Parent of Fork
			# 
			#  Audio/Video Encoders should be running now
        		if ($VERB >= 0) {
        			print CONSOLE_OUTPUT "[$file_num] Starting Encode for \"$OUTPUT_FILE\" at " . (time - $start) . " seconds.\n";
        		}
        	} elsif ($comp_video_pid == 0) {
			# Child Fork
			if ($NOVIDEO) {
				exit(0);
			}

        		($EUID, $EGID) = ($UID, $GID); # suid only
        
        		# Video Encoder
        		if ($VERB > 1 || $TEST) {
        			print "\n$X264 @CVCMD\n";
        		}
        		if (!$TEST) {
				if (open_io("COMP_VIDEO_LOG", $vinput, "Video Encoder")) {
					$ContinueTranscoding = 0;
					exit(1);
				}

                        	if (system($X264, @CVCMD)) {
					show_error($?, $!, "Video Encoder");
					close_io("Video Encoder");
					$ContinueTranscoding = 0;
					exit(1);
				}

				if (close_io("Video Encoder")) {
					exit(1);
				}

				exit(0);
        		} else {
				exit(0);
			}
        	} else {
			# Fork Failed
		}
        } elsif($comp_audio_pid == 0) {
		# Child Fork
		if ($NOAUDIO) {
			exit(0);
		}

        	($EUID, $EGID) = ($UID, $GID); # suid only
        
        	# Audio Encoder
        	if ($VERB > 1 || $TEST) {
        		print "\n$AACENC @CACMD\n";
        	}
        	if (!$TEST) {
			if (open_io("COMP_AUDIO_LOG", $ainput, "Audio Encoder")) {
				$ContinueTranscoding = 0;
				exit(1);
			}

                        if (system($AACENC, @CACMD)) {
				show_error($?, $!, "Audio Encoder");
				close_io("Audio Encoder");
				$ContinueTranscoding = 0;
				exit(1);
			}

			if (close_io("Audio Encoder")) {
				exit(1);
			}

			exit(0);
        	} else {
			exit(0);
		}
        } else {
		# Fork Failed
		return 1;
	}
        
	# If we have Audio
	if (!$TEST && !$NOAUDIO) {
        	# Wait for Audio Encoder pid to exit
       	 	if (wait_for_pid($comp_audio_pid, "Audio Encoder", $aoutput, 0) == 1) {
        		print CONSOLE_OUTPUT "ERROR: Audio Encoder failed to execute\n";
			$ContinueTranscoding = 0;
        	}

		# Check if Audio failed
		if (show_encoding_info($aoutput, "Encode Audio")) {
			# Failed
			$ContinueTranscoding = 0;
			return 1;
		}
	}

	# If we have Video
	if (!$TEST && !$NOVIDEO) {
        	# Wait for Video Encoder pid to exit
        	if (wait_for_pid($comp_video_pid, "Video Encoder", $voutput, 0) == 1) {
        		print CONSOLE_OUTPUT "ERROR: Video Encoder failed to execute\n";
			$ContinueTranscoding = 0;
        	}

		# Check if Video failed
		if (show_encoding_info($voutput, "Encode Video")) {
			# Failed
			$ContinueTranscoding = 0;
			return 1;
		}
	}

	return 0;
}

# Mux Audio/Video together
sub mux_av {
	my $count = shift;
	my $afifo = shift;
	my $vfifo = shift;
	my $astring = shift;
	my $vstring = shift;
	my $ofile = shift;

	my $muxer_pid;

	# Only necessary if we actually have Audio/Video to Mux
	if ($NOVIDEO) {
		move($afifo, $ofile) or print CONSOLE_OUTPUT (qq{failed to move $afifo -> $ofile \n});
		return 0;
	}
	if ($NOAUDIO) {
		move($vfifo, $ofile) or print CONSOLE_OUTPUT (qq{failed to move $vfifo -> $ofile \n});
		return 0;
	}
        # 
        # Muxer Fork
        #
        $muxer_pid = get_new_pid("A/V MP4 Muxer", $ofile);
        if ($muxer_pid > 0) {   
        	# Muxer Parent Process
        
        	# Wait for Muxer pid to exit
        	if (!$TEST && wait_for_pid($muxer_pid, "A/V MP4 Muxer", "", 0) == 1) {
			$ContinueTranscoding = 0;
        		print CONSOLE_OUTPUT "ERROR: Muxer failed to execute\n";
        	}

		# Remove tmp streams
		foreach(@streams) {
			if (-f $_) {
				unlink($_);
			}
		}
		@streams = ();

		# Remove or move Separate Audio/Video Streams
		if (-f $vfifo) {
			if (!$KEEPSTREAMS) {
				unlink($vfifo);
			} else {
				if ($NOAUDIO) {
					move($vfifo, $ofile . ".mp4") or print CONSOLE_OUTPUT (qq{failed to move $vfifo -> $ofile.mp4 \n});
				} else {
					move($vfifo, $ofile . ".264") or print CONSOLE_OUTPUT (qq{failed to move $vfifo -> $ofile.264 \n});
				}
			}
		}
		if (-f $afifo) {
			if (!$KEEPSTREAMS) {
				unlink($afifo);
			} else {
				if ($NOVIDEO) {
					move($afifo, $ofile . ".m4a") or print CONSOLE_OUTPUT (qq{failed to move $afifo -> $ofile.m4a \n});
				} else {
					move($afifo, $ofile . ".aac") or print CONSOLE_OUTPUT (qq{failed to move $afifo -> $ofile.aac \n});
				}
			}
		}

		if (!$TEST) {
			# Show Encoding Info
			show_encoding_info($ofile, "Mux Audio/Video");
		}
        } elsif ($muxer_pid == 0) {
        	# Muxer Child Process
        	($EUID, $EGID) = ($UID, $GID); # suid only
        
        	# Audio/Video Delay to Sync
        	if ($SYNC) {
        		($type, $delay) = split(/\s/, $stream_delay[0]);
        		if ($delay) {
        			if ($type =~ /video/i) {
        				$vdelay = ":delay=$delay";
        		}	 else {
        				$adelay = ":delay=$delay";
        			}
        		}
        	}
        	# Verbosity
        	if ($VERB < 1) {
        		$QUIET = "-quiet";
        	}
        	# FPS Change
        	if ($FPS_DIFF) {
        		$OFPS += $FPS_DIFF;
        	}
        
        	# Combine Streams Command
        	my $ACOMBCMD = "-nosys $QUIET -fps $OFPS -flat $astring -new $afifo";
        	my $VCOMBCMD = "-nosys $QUIET -fps $OFPS -flat $vstring -new $vfifo";

		my $MFILES = "";
		if ($NOVIDEO) {
			$MFILES = "-add $afifo#audio$adelay";
		} elsif ($NOAUDIO) {
			$MFILES = "-fps $OFPS -add $vfifo#video$vdelay";
		} else {
			$MFILES = "-fps $OFPS -add $vfifo#video$vdelay -add $afifo#audio$adelay";
		}
        
        	# Mux Command
        	my (@MUXCMD) = split(/\s+/, 
        		"-inter 1000 $QUIET $MUXOPTS $MFILES");
        
        	# MUX AUDIO and VIDEO to MP4 FORMAT
        	my (@MUXERARGS) = ();
        	push(@MUXERARGS, @MUXCMD);
        	push(@MUXERARGS, "-new");
        	push(@MUXERARGS, $ofile);
        
        	if ($VERB > 1 || $TEST) {
        		# Combine
        		if ($count > 1) {
        			print "\n$MP4BOX $ACOMBCMD\n";
        			print "\n$MP4BOX $VCOMBCMD\n";
        		}
        		# Mux
        		print "\n$MP4BOX @MUXERARGS\n";
        	}
        	if (!$TEST) {
			if (open_io("MUXER_LOG", "/dev/null", "A/V MP4 Muxer")) {
				$ContinueTranscoding = 0;
				exit(1);
			}

        		# Multiple Input Files
        		if ($count > 1) {
        			# Combine Streams
        			if (system("$MP4BOX $ACOMBCMD")) {
					show_error($?, $!, "A/V MP4 Audio Combine");
					$ContinueTranscoding = 0;
					exit(1);
				}
        			if (system("$MP4BOX $VCOMBCMD")) {
					show_error($?, $!, "A/V MP4 Video Combine");
					$ContinueTranscoding = 0;
					exit(1);
				}
        		}

        		# Muxer Exec
                       	if (system($MP4BOX, @MUXERARGS)) {
				show_error($?, $!, "A/V MP4 Muxer");
				close_io("A/V MP4 Muxer");
				$ContinueTranscoding = 0;
				exit(1);
			}

			if (close_io("A/V MP4 Muxer")) {
				exit(1);
			}
			exit(0);
        	} else {
			exit(0);
		}
        } else {
		# Fork failed
		return 1;
	}		
}

# Wait for a pid to exit
sub wait_for_pid {
	my $pid = shift;
	my $pid_name = shift;
	my $file = shift;
	my $timeout = shift;
	my $noinfo = shift;
	my ($loop) = 1;
	my ($ms) = 0;
	my ($i) = 0;
	my (@spinner) = ('-','\\','|','/');

        # Get child index for access to pid/file/name/status
	my $done = 0;
	my $child_index = -1;
        my $num_children = scalar(@children);
        for(my $i = 0; !$done && $i < $num_children; $i++) {
                if (!$children[$i]{'pid'}) {
                        next;
                }
		if ($children[$i]{'pid'} == $pid) {
			$child_index = $i;
			$done = 1;
		}
        }

       	my $pidval = waitpid ($pid, WNOHANG);
	if ($pidval == $pid || $pidval < 0) {
		# Not Running
		$children[$child_index]{'status'} = "Not Running: (" . $? . ")";
		return 0;
	}

	if ($VERB >= 0 && !$TEST && $ContinueTranscoding) {
		print CONSOLE_OUTPUT "\n";
	}

	while (!$TEST && $loop && $ContinueTranscoding && ($timeout == 0 || $timeout > $ms)) {
		# output file check
		if ($ms > 10 && !$RAW_AUDIO_INPUT && !$RAW_VIDEO_INPUT) {
			if ($file && (! -f $file && ! -p $file) || ( -f $file && age_of_file_in_seconds($file) > 10)) {
				# Must not be working
				$loop = 0;
                		print CONSOLE_OUTPUT "ERROR: [$pid] $pid_name \"$file\" isn't being created.\n ";
				next;
			}
		}

		# Spinner Counter
        	$i++;
        	if ($i > 3) {
                	$i = 0;
        	}

		# Waitpid
        	$pidval = waitpid ($pid, WNOHANG);
        	if ($pidval < 0) {
			$children[$child_index]{'status'} = "Doesn't Exist: (" . $? . ")";
                	print CONSOLE_OUTPUT "[$pidval] $pid_name Child $pid $children[$child_index]{'status'}\n ";

			# PID failed
			return 1;
        	} elsif ($pidval == $pid) {
                       	$children[$child_index]{'status'} = "Exited: (" . $? . ")";
                	if (!$noinfo && $VERB > 1) {
                        	print CONSOLE_OUTPUT "\r [$pidval] $pid_name Child $pid $children[$child_index]{'status'}";
				if ($? == 0) {
					print CONSOLE_OUTPUT "\r                                                       ";
				} else {
					print "\n";
				}
                	} elsif (!$noinfo && $VERB >= 0) {
				print CONSOLE_OUTPUT "\r                                                       ";
			}

			# PID Finished
			return 0;
        	} else {
                	$children[$child_index]{'status'} = "Running for $ms ms";
        		if (!$noinfo && $VERB >= 0) {
                		if ($i % 2) {
                			$spinner = "|";
                		} else {
                        		$spinner = "-";
                		}
				printf(CONSOLE_OUTPUT "\r [%05d] %s (%04.2f) total (%04d)  %s\t",
                			$pid, $pid_name, $ms, (time - $start), $spinner[$i]);
					
        		}
        		select(undef, undef, undef, 0.25);
        		$ms += .25;
		}
	}
	# Did we timeout
	if ($timeout > 0 && $ms >= $timeout) {
               	$children[$child_index]{'status'} = "Timed out at $ms ms";
		return 1;
	}
        $children[$child_index]{'status'} = "Finished";
	return 0;
}

# Fork a new pid/process
sub get_new_pid {
	my $ms = 0;
	my $sleep_count = 0;
	my $pid_name = shift;
	my $file = shift;
	my $pid;

	# Get PID
	do {
        	$pid = fork();
        	unless (defined $pid) {
            		print CONSOLE_OUTPUT "[$ms] cannot fork $pid_name: $!\n";
			if ($sleep_count++ > 8) {
            			print CONSOLE_OUTPUT "bailing out of $pid_name pid at $ms seconds.\n";
				$ContinueTranscoding = 0;
				return -1;
			}

       	    		select(undef, undef, undef, 0.25);
	    		$ms += 0.25;
        	}
	} until defined $pid;

	# Save PID
	if ($pid > 0) {
		push(@children, { pid => $pid, name => $pid_name, file => $file, status => "Starting..."});
	}

	return $pid;
}

# Input Options
sub get_options {
	my $result = 0;
        # get value of input flags
        $result = GetOptions (
                "help|h" => \$help,
                "test" => \$TEST,
                "log|l" => \$KEEPLOGFILES,
                "time|t=s" => \$TIME,
                "autoconf|a=s" => \$AUTOCONF,
		"maxwidth|mw=s" => \$MAXWIDTH,
		"sws=s" => \$SWS,
                "precheck|pc" => \$PRECHECK,
                "infmt|if=s" => \$INPUTFORMAT,
                "noaudio|na" => \$NOAUDIO,
                "novideo|nv" => \$NOVIDEO,
                "demux|x" => \$KEEPSTREAMS,
                "verbose|v" => \@VERBOSE,
                "overwrite|y" => \$OVERWRITE,
                "codec|c=s" => \$USE_CODEC,
                "directory|d=s" => \$INPUT_DIRECTORY,
                "pattern|p=s" => \$INPUT_PATTERN,
                "input|i=s" => \@INPUT_FILE,
                "audioinput|ai=s" => \$RAW_AUDIO_INPUT,
                "videoinput|vi=s" => \$RAW_VIDEO_INPUT,
                "segsecs|ss=s" => \$SPLIT_SECS,
                "output|o=s" => \$OUTPUT_FILE,
                "aspect|asr=s" => \$ASPECT,
                "sar=s" => \$SAR,
                "aacenc|aac=s" => \$AACENC,
                "fpsdiff|fd=s" => \$FPS_DIFF,
                "sync" => \$SYNC,
                "newsync=s" => \$SYNC,
                "nosync" => \$NOSYNC,
                "async=s" => \$ASYNC,
                "vsync=s" => \$VSYNC,
                "ngtc" => \$USE_DECODEAV,
                "ffmpeg" => \$USE_FFMPEG,
                "noffmpeg" => \$USE_MENCODER,
                "oldffmpeg" => \$USE_OLD_FFMPEG,
                "usey4m|y4m" => \$VIDEO_USE_Y4M,
                "usewav|wav" => \$AUDIO_USE_WAV,
                "bitrate|b=s" => \$VBRATE,
                "ofps|r=s" => \$OFPS,
                "fsize|s=s" => \$FSIZE,
                "abitrate|ab=s" => \$ABRATE,
                "arate|ar=s" => \$ARATE,
                "achan|ac=s" => \$ACHAN,
                "crf=s" => \$CRF,
                "profile|pf=s" => \$PROFILE,
                "level|lvl=s" => \$LEVEL,
                "showcodec|sc" => \$SHOWCODEC,
                "enc|e=s" => \$ENCODE,
                "audiopreload|apl=s" => \$AUDIO_PRELOAD,
        );

	if ($ENCODE) {
		$SEPARATE = 0;
		($FORMAT, $VCODEC, $ACODEC) = split(/:/, $ENCODE);
		if (!$VCODEC) {
			$NOVIDEO = 1;
		}
		if (!$ACODEC) {
			$NOAUDIO = 1;
		}
	}

	if ($USE_OLD_FFMPEG) {
		$USE_FFMPEG;
	}

	if ($RAW_AUDIO_INPUT || $RAW_VIDEO_INPUT) {
		if (-f $RAW_AUDIO_INPUT || -p $RAW_AUDIO_INPUT) {
			$INPUT_FILE[0] = $RAW_AUDIO_INPUT;
		} else {
			$RAW_AUDIO_INPUT = "/dev/null";
		}
		if (-f $RAW_VIDEO_INPUT || -p $RAW_VIDEO_INPUT) {
			$INPUT_FILE[0] = $RAW_VIDEO_INPUT;
		} else {
			$RAW_VIDEO_INPUT = "/dev/null";
		}
	}

	return $result;
}

# Help Output
sub help {
	print "\nVersion $VERSION by Chris Kennedy (C) 2009\n";
	print "\n$0 Usage:\n";
	print "\t-h -help\t\t\tHelp\n";
	print "\t-i -input <file>\t\tInput file name, can be specified multiple times\n";
	print "\t-vi -videoinput <file>\t\tRaw Video Input file name\n";
	print "\t-ai -audioinput <file>\t\tRaw Audio Input file name\n";
	print "\t-o -output <file>\t\tOutput file name\n";
	print "\t-test\t\t\t\tTest run, don't actually run commands\n";
	print "\t-sc -showcodec\t\t\tShow Codec configuration file\n";
	print "\t-l -log\t\t\t\tKeep log files and save with output file\n";
	print "\t-t -time <secs>\t\t\tLength in seconds to encode\n";
	print "\t-a -autoconf [0|1]\t\tUse video/audio settings from source video\n";
	print "\t-mw -maxwidth <width>\t\tMaximum width, scale to this size\n";
	print "\t-sws <0-10>\t\t\tMplayer/Mencoder software scaling method, 0=low q 10=best\n";
	print "\t-apl -audiopreload <ms>\t\tMplayer/Mencoder audio ms to preload, default 0.0\n";
	print "\t-pc -precheck\t\t\tGet file information to use if no bitrate/framesize/fps set\n";
	print "\t-if -infmt\t\t\tInput format string for decoder if using raw yuv/pcm files\n";
	print "\t-na -noaudio\t\t\tNo Audio input/output\n";
	print "\t-nv -novideo\t\t\tNo Video input/output\n";
	print "\t-sync\t\t\t\tFind if an Audio/Video delay exist and sync streams\n";
	print "\t-newsync\t\t\tAudio/Video delay value, don't use av offset from original file\n";
	print "\t-async\t\t\t\tPass Audio sync option value to ffmpeg/mencoder decoder\n";
	print "\t-vsync\t\t\t\tPass Video sync option value to ffmpeg/mencoder decoder\n";
	print "\t-ngtc\t\t\t\tUse ngtc as decoder for audio/video\n";
	print "\t-ffmpeg\t\t\t\tUse FFMPEG as decoder for audio/video\n";
	print "\t-noffmpeg\t\t\tDon't Use FFMPEG as decoder for audio/video\n";
	print "\t-oldffmpeg\t\t\tUse Older FFMPEG as decoder for audio/video\n";
	print "\t-x -demux\t\t\tSave demuxed raw Audio/Video streams\n";
	print "\t-v -verbose\t\t\tIncrease verbosity per -v\n";
	print "\t-y -overwrite\t\t\tOverwrite output file if it exists\n";
	print "\t-c -codec <file>\t\tCodec file to use for encoding settings\n";
	print "\t-b -bitrate <bps>\t\tBitrate in bps (1000000 = 1Mbit)\n";
	print "\t-ab -abitrate <bps>\t\tAudio Bitrate in bps (128000 = 128kbit)\n";
	print "\t-ar -arate <rate>\t\tAudio sample rate in khz (44100 = 44.1khz)\n";
	print "\t-ac -achan <channels>\t\tAudio channels\n";
	print "\t-r -ofps <framerate>\t\tVideo Framerate, FPS of output video\n";
	print "\t-s -framesize <HxW>\t\tVideo Framesize of output video HxW\n";
	print "\t-crf <1-51>\t\t\tCRF or constant rate factor, quantization average\n";
	print "\t-lvl -level <1-5>\t\tH.264 Level for hardware devices, not usually needed\n";
	print "\t-pf -profile <type>\t\tProfile type, baseline|main|high, H.264 specs\n";
	print "\t-d -directory <dir>\t\tDirectory to scan for files\n";
	print "\t-p -pattern <regexp>\t\tFile Pattern to look for in scan directory\n";
	print "\t-ss -segsecs <seconds>\t\tOutput file segments length in seconds\n";
	print "\t-asr -aspect <int:int>\t\tAspect Ratio\n";
	print "\t-sar <int:int>\t\t\tSource Aspect Ratio\n";
	print "\t-aac -aacenc [nero|faac] \tChoose either FAAC or NERO for AAC Audio Encoding\n";
	print "\t-wav -usewav\t\t\tUse wav format for audio pcm samples\n";
	print "\t-y4m -usey4m\t\t\tUse Y4M format for video yuv samples\n";
	print "\t-fd -fpsdiff <float>\t\tFPS add/sub amount when Muxing Raw video, for sync problems\n";
	print "\t-e -enc <fmt:vcodec:acodec>\tEncode using ffmpeg\n";
	print "\n";
}

# Setup Executables
sub setup_exe {
	if ($^O eq "MSWin32") {
        	$IS_WINDOWS = 1;
	}

	if ($IS_WINDOWS) {
       		$FFMPEG="ffmpeg.exe";
	} else {
       		$FFMPEG="/usr/local/bin/WMVffmpeg";
       		$INFOFFMPEG="/usr/local/bin/WMVffmpeg";
       		$OLDFFMPEG="/usr/local/bin/WMVffmpeg-JUNE2008";
       		#$NEWFFMPEG="/usr/local/bin/WMVffmpeg-new";
		if ($USE_OLD_FFMPEG) {
			$FFMPEG = $OLDFFMPEG;
		}
       		$DECODEAV="/usr/local/bin/ngtc";
	}

	if ($IS_WINDOWS) {
       		$MENCODER="mencoder.exe";
	} else {
       		$MENCODER="/usr/local/bin/mencoder";
	}

	if ($IS_WINDOWS) {
       		$MPLAYER="mplayer.exe";
	} else {
       		$MPLAYER="/usr/local/bin/mplayer";
	}

	if ($IS_WINDOWS) {
       		$X264="x264.exe";
	} else {
       		$X264="/usr/local/bin/x264";
	}

	if ($IS_WINDOWS) {
       		$FAAC="faac.exe";
	} else {
       		$FAAC="/usr/local/bin/faac";
	}

	if ($IS_WINDOWS) {
       		$NERO="neroAacEnc.exe";
	} else {
       		$NERO="/usr/local/bin/neroAacEnc";
	}

	if ($IS_WINDOWS) {
       		$MEDIAINFO="mediainfo.exe";
	} else {
       		$MEDIAINFO="/usr/local/bin/mediainfo";
	}

	if ($IS_WINDOWS) {
       		$MP4BOX="MP4Box.exe";
	} else {
       		$MP4BOX="/usr/local/bin/MP4Box";
	}

	if ($IS_WINDOWS) {
        	$TMP_DIR="C:\\\\temp";
        	$TMP_SLASH="\\";
	} else {
        	$TMP_DIR = "/var/tmp";
        	$TMP_SLASH="/";
	}

	# Choose Audio Encoder
	if ($AACENC eq "nero") {
		$AACENC = $NERO;
		$AUDIO_USE_WAV = 1;
	} elsif ($AACENC eq "faac") {
		$AACENC = $FAAC;
	} else {
		# Default to faac
		$AACENC = $FAAC;
	}

	if (!$USE_MENCODER && $NOVIDEO) {
		$USE_FFMPEG = 1;
		if ($VERB > 0) {
			print CONSOLE_OUTPUT "Using $FFMPEG with $AACENC.\n";
		}
	}

	# FFMPEG Threads
	if (!$IS_WINDOWS) {
                # Calculate optimal threads for FFMPEG
                my $NUM_CPUS = `cat /proc/cpuinfo |grep ^processor|wc -l`;
                chomp($NUM_CPUS);
                $DECTHREADS = $NUM_CPUS;
                if ($DECTHREADS == 2) {
                        $DECTHREADS += 1;
                }
	}

	if (! -d $TMP_DIR) {
		print CONSOLE_OUTPUT "ERROR: temporary directory $TMP_DIR doesn't exist, please create.\n";
		exit(1);
	}
}

# Setup Verbosity
sub setup_verb {
	$VERBOSE = scalar(@VERBOSE);

	if ($VERBOSE > 3) {
        	# Verbose = 4+
        	$VERB = 3;
        	$FFVERB = 2;
        	$MEVERB = "6";
        	$LOGLEVEL = 48;
		if (!$KEEPLOGS) {
			$LOGFILES = 0;
		}
	} elsif ($VERBOSE == 3) {
        	# Verbose = 3
        	$VERB = 2;
        	$FFVERB = 1;
        	$MEVERB = "5 -quiet";
        	$LOGLEVEL = 40;
		if (!$KEEPLOGS) {
			$LOGFILES = 0;
		}
	} elsif ($VERBOSE == 2) {
        	# Verbose = 2
        	$VERB = 1;
        	$FFVERB = 0;
        	$MEVERB = "4 -quiet";
        	$LOGLEVEL = 32;
	} elsif ($VERBOSE == 1) {
        	# Verbose = 1
        	$VERB = 0;
        	$FFVERB = -1;
        	$MEVERB = "3 -quiet";
        	$LOGLEVEL = 24;
	} else {
        	# Verbose = 0
        	$VERB = -1;
        	$FFVERB = -1;
        	$MEVERB = "2 -quiet -really-quiet";
        	$LOGLEVEL = -8;
	}

	if ($TEST) {
		$LOGFILES = 0;
	}
}

# Check input args
sub check_args {
	if ($INPUT_DIRECTORY) {
		if (! -d $INPUT_DIRECTORY) {
			print CONSOLE_OUTPUT "ERROR: input directory $INPUT_DIRECTORY doesn't exist.\n";
			exit(1);
		} else {
			if ($VERB > 1) {
				print CONSOLE_OUTPUT "Scanning input directory $INPUT_DIRECTORY for pattern /$INPUT_PATTERN/.\n";
			}
		}
	} else {
		if (!scalar(@INPUT_FILE)) {
			help();
			print CONSOLE_OUTPUT "ERROR: input file not specified.\n";
			exit(1);
		}
		foreach (@INPUT_FILE) {
			if (! -f $_ && ! -p $_) {
				print CONSOLE_OUTPUT "ERROR: input file $_ doesn't exist.\n";
				exit(1);
			} else {
				$i++;
				if ($VERB > 1) {
					print CONSOLE_OUTPUT "[$i] Input file $_ exists.\n";
				}
			}
		}
	}
	if (!$OUTPUT_FILE) {
		help();
		print CONSOLE_OUTPUT "ERROR: output file not specified.\n";
		exit(1);
	}
	if (!$OVERWRITE && -f $OUTPUT_FILE && !$TEST) {
		print CONSOLE_OUTPUT "ERROR: output file $OUTPUT_FILE already exists.\n";
		exit(1);
	} elsif (-f $OUTPUT_FILE && !$TEST) {
		unlink($OUTPUT_FILE);
	}
}

# Get base name
sub file_name {
	my $name = shift;

	$name =~ s/.*$TMP_SLASH//g;
	$name =~ s/\..*$//g;

	if ($VERB > 0) {
		print CONSOLE_OUTPUT "Basename: $name\n";
	}
	return $name;
}

# Setup Log File Locations
sub log_file_locations {
        # Log file locations
        if ($LOGFILES) {
        	$MAIN_LOG = $TMP_DIR . $TMP_SLASH . $OUTPUT_NAME . "_" . $$ . "_main.log";
        	$RAW_AUDIO_LOG = $TMP_DIR . $TMP_SLASH . $OUTPUT_NAME . "_" . $$ . "_adec.log";
        	$RAW_VIDEO_LOG = $TMP_DIR . $TMP_SLASH .  $OUTPUT_NAME . "_" . $$ . "_vdec.log";
        	$COMP_AUDIO_LOG = $TMP_DIR . $TMP_SLASH . $OUTPUT_NAME . "_" . $$ . "_aenc.log";
        	$COMP_VIDEO_LOG = $TMP_DIR . $TMP_SLASH . $OUTPUT_NAME . "_" . $$ . "_venc.log";
        	$MUXER_LOG = $TMP_DIR . $TMP_SLASH . $OUTPUT_NAME . "_" . $$ . "_avmux.log";
        
        	open MAIN_LOG, ">$MAIN_LOG" or die "Can't open Main Log: $!";
        	open COMP_AUDIO_LOG, ">$COMP_AUDIO_LOG" or die "Can't open Audio Encoding Log: $!";
        	open RAW_AUDIO_LOG, ">$RAW_AUDIO_LOG" or die "Can't open Audio Decoding Log: $!";
        	open COMP_VIDEO_LOG, ">$COMP_VIDEO_LOG" or die "Can't open Video Encoding Log: $!";
        	open RAW_VIDEO_LOG, ">$RAW_VIDEO_LOG" or die "Can't open Video Decoding Log: $!";
        	open MUXER_LOG, ">$MUXER_LOG" or die "Can't open Muxer Log: $!";

        	select MAIN_LOG; $| = 1;
        	select COMP_AUDIO_LOG; $| = 1;
        	select RAW_AUDIO_LOG; $| = 1;
        	select COMP_VIDEO_LOG; $| = 1;
        	select RAW_VIDEO_LOG; $| = 1;
        	select MUXER_LOG; $| = 1;
        } 
	#else { 
        #	open MAIN_LOG, '>', \$MAIN_LOG or die "Can't open Main Log: $!";
        #	open COMP_AUDIO_LOG, '>', \$COMP_AUDIO_LOG or die "Can't open Audio Encoding Log: $!";
        #	open RAW_AUDIO_LOG, '>', \$RAW_AUDIO_LOG or die "Can't open Audio Decoding Log: $!";
        #	open COMP_VIDEO_LOG, '>', \$COMP_VIDEO_LOG or die "Can't open Video Encoding Log: $!";
        #	open RAW_VIDEO_LOG, '>', \$RAW_VIDEO_LOG or die "Can't open Video Decoding Log: $!";
        #	open MUXER_LOG, '>', \$MUXER_LOG or die "Can't open muxer Log: $!";
        #}
}

# Setup File Locations
sub file_locations {
	# Raw Audio fifo
	if (!$RAW_AUDIO_INPUT) {
		if ($AUDIO_USE_WAV) {
        		$RAW_AUDIO_FIFO = $TMP_DIR . $TMP_SLASH . $OUTPUT_NAME . "_" . $$ . "_adec.wav";
		} else {
        		$RAW_AUDIO_FIFO = $TMP_DIR . $TMP_SLASH . $OUTPUT_NAME . "_" . $$ . "_adec.pcm";
		}
	} else {
		$RAW_AUDIO_FIFO = $RAW_AUDIO_INPUT;
	}

	# Raw Video fifo
	if (!$RAW_VIDEO_INPUT) {
		if ($VIDEO_USE_Y4M) {
        		$RAW_VIDEO_FIFO = $TMP_DIR . $TMP_SLASH . $OUTPUT_NAME . "_" . $$ . "_vdec.y4m";
		} else {
        		$RAW_VIDEO_FIFO = $TMP_DIR . $TMP_SLASH . $OUTPUT_NAME . "_" . $$ . "_vdec.yuv";
		}
	} else {
		$RAW_VIDEO_FIFO = $RAW_VIDEO_INPUT;
	}

	# Compressed Audio file
	if ($NOVIDEO) {
        	$COMP_AUDIO_FIFO = $TMP_DIR . $TMP_SLASH . $OUTPUT_NAME . "_" . $$ . "_aenc.m4a";
	} else {
        	$COMP_AUDIO_FIFO = $TMP_DIR . $TMP_SLASH . $OUTPUT_NAME . "_" . $$ . "_aenc.aac";
	}

	# Compressed Video file
	if ($NOAUDIO) {
        	$COMP_VIDEO_FIFO = $TMP_DIR . $TMP_SLASH . $OUTPUT_NAME . "_" . $$ . "_venc.mp4";
	} else {
        	$COMP_VIDEO_FIFO = $TMP_DIR . $TMP_SLASH . $OUTPUT_NAME . "_" . $$ . "_venc.264";
	}
}

# Setup Fifo's
sub setup_fifo {
	# create raw and comp audio fifo
	if (!$RAW_AUDIO_INPUT) {
		if (! -p $RAW_AUDIO_FIFO) {
			mkfifo($RAW_AUDIO_FIFO, 0700);
		}
		if (! -p $RAW_AUDIO_FIFO) {
			print CONSOLE_OUTPUT "ERROR: raw audio fifo $RAW_AUDIO_FIFO doesn't exist.\n";
			exit(1);
		}
	} else {
		if (! -p $RAW_AUDIO_INPUT && ! -f $RAW_AUDIO_INPUT) {
			print CONSOLE_OUTPUT "ERROR: raw audio input $RAW_AUDIO_INPUT doesn't exist.\n";
			exit(1);
		}
	}

	# create raw and comp video fifo
	if (!$RAW_VIDEO_INPUT) {
		if (! -p $RAW_VIDEO_FIFO) {
			mkfifo($RAW_VIDEO_FIFO, 0700);
		}
		if (! -p $RAW_VIDEO_FIFO) {
			print CONSOLE_OUTPUT "ERROR: raw video fifo $RAW_VIDEO_FIFO doesn't exist.\n";
			cleanup();
			exit(1);
		}
	} else {
		if (! -p $RAW_VIDEO_INPUT && ! -f $RAW_VIDEO_INPUT) {
			print CONSOLE_OUTPUT "ERROR: raw video input $RAW_VIDEO_INPUT doesn't exist.\n";
			exit(1);
		}
	}
}

# Codec to local configuration 
sub set_codec {
	$RAWVIDOPTS = "";
	$MUXOPTS = "";

        if ($CODEC{'inputformat'} != -1) {
                $INPUTFORMAT = $CODEC{'inputformat'};
        }
        if ($CODEC{'maxwidth'} != -1) {
                $MAXWIDTH = $CODEC{'maxwidth'};
        }
        if ($CODEC{'sync'} != -1) {
		if (!$NOSYNC) {
                	$SYNC = $CODEC{'sync'};
		}
        }
        if (!$PROFILE && $CODEC{'profile'} != -1) {
                $PROFILE = $CODEC{'profile'};
        }
        if ($CODEC{'level'} != -1) {
                $LEVEL = $CODEC{'level'};
        }
        if ($CODEC{'aspect'} != -1) {
                $ASPECT = $CODEC{'aspect'};
        }
        if ($CODEC{'sar'} != -1) {
                $SAR = $CODEC{'sar'};
        }
        if ($AUTOCONF && $ORIG_FRAMERATE > 0 && $OFPS <= 0 && $CODEC{'framerate'} <= 0) {
		# Autoconf
               	$OFPS = $ORIG_FRAMERATE;

		if ($OFPS > 60) {
			$OFPS = 60;
		}
        } elsif ($CODEC{'framerate'} > 0 && $OFPS == -1) {
                $OFPS = $CODEC{'framerate'};
        } elsif (!$CODEC{'framerate'} && $OFPS == -1) {
		if ($ORIG_FRAMERATE > 0 && $ORIG_FRAMERATE <= 60) {
			$OFPS = $ORIG_FRAMERATE;
		}
	}
	if ($OFPS <= 0) {
		$OFPS = "29.970";
	}
        if ($CODEC{'maxgop'} > 0) {
		$MAXGOP = $CODEC{'maxgop'};
	}
        if ($CODEC{'gopsize'} > 0) {
                $GOP = $CODEC{'gopsize'};
        }
	# Check GOP Size
	($GOP, $MINGOP) = check_gop($GOP, $MAXGOP, $OFPS);

        if ($AUTOCONF && $ORIG_HEIGHT && $ORIG_WIDTH && $FSIZE <= 0 && $CODEC{'framesize'} <= 0) {
		# Autoconf
                $FSIZE = $ORIG_WIDTH . "x" . $ORIG_HEIGHT;
        } elsif ($CODEC{'framesize'} > 0 && $FSIZE == -1) {
                $FSIZE = $CODEC{'framesize'};
        } elsif (!$CODEC{'framesize'} && $FSIZE == -1) {
		if ($ORIG_HEIGHT && $ORIG_WIDTH) {
			$FSIZE = $ORIG_WIDTH . "x" . $ORIG_HEIGHT;
		}
	}
        if ($AUTOCONF && $ORIG_BITRATE && $CODEC{'bitrate'} <= 0 && $VBRATE <= 0) {
        	# Autoconf: Take default settings from original media
               	$VBRATE = $ORIG_BITRATE;
        } elsif ($VBRATE == 0 && $CODEC{'bitrate'} > 0) {
                $VBRATE = $CODEC{'bitrate'};
        }
        if ($CODEC{'maxrate'} > 0) {
                $MAXRATE = $CODEC{'maxrate'};
        }
        if ($CODEC{'bufsize'} > 0) {
                $BUFSIZE = $CODEC{'bufsize'};
        }
        if ($AUTOCONF && $ORIG_AUDIO_BITRATE && $ABRATE <= 0 && $CODEC{'abitrate'} <= 0) {
		# Autoconf
                $ABRATE = $ORIG_AUDIO_BITRATE;
        } elsif ($CODEC{'abitrate'} > 0 && $ABRATE == -1) {
                $ABRATE = $CODEC{'abitrate'};
        }
	if ($ABRATE <= 0) {
		$ABRATE = "192000";
	}
        if ($AUTOCONF && $ORIG_AUDIO_RATE && $ARATE <= 0 && $CODEC{'audiorate'} <= 0) {
		# Autoconf
                $ARATE = $ORIG_AUDIO_RATE;
        } elsif ($CODEC{'audiorate'} > 0 && $ARATE == -1) {
                $ARATE = $CODEC{'audiorate'};
        }
	if ($ARATE <= 0) {
		$ARATE = "44100";
	}
        if ($AUTOCONF && $ORIG_AUDIO_NCH && $ACHAN <= 0 && $CODEC{'channels'} <= 0) {
		# Autoconf
                $ACHAN = $ORIG_AUDIO_NCH;
        } elsif ($CODEC{'channels'} > 0 && $ACHAN == -1) {
                $ACHAN = $CODEC{'channels'};
        }
	if ($ACHAN <= 0) {
		$ACHAN = "2";
	}
	if ($CODEC{'partitions'} != -1) {
	        $PARTITIONS = $CODEC{'partitions'};
        }
        if ($CODEC{'me_method'} != -1) {
                $ME = $CODEC{'me_method'};
        }
        if ($CODEC{'me_chroma'} != -1) {
                $MECHROMA = $CODEC{'me_chroma'};
        }
        if ($CODEC{'me_range'} != -1) {
                $MERANGE = $CODEC{'me_range'};
        }
        if ($CODEC{'directpred'} != -1) {
                $DIRECT = $CODEC{'directpred'};

		if ($DIRECT == 0) {
			$DIRECT = "none";
		} elsif ($DIRECT == 1) {
			$DIRECT = "spatial";
		} elsif ($DIRECT == 2) {
			$DIRECT = "temporal";
		} elsif ($DIRECT == 3) {
			$DIRECT = "auto";
		} else {
			$DIRECT = "auto";
		}
        }
        if ($CODEC{'subq'} != -1) {
                $SUBME = $CODEC{'subq'};
        }
        if ($CODEC{'qcomp'} != -1) {
                $QCOMP = $CODEC{'qcomp'};
        }
        if ($CODEC{'cabac'} != -1) {
                $CABAC = $CODEC{'cabac'};
        }
        if ($CODEC{'badapt'} != -1) {
                $BADAPT = $CODEC{'badapt'};
        }
        if ($CODEC{'bframes'} != -1) {
                $BF = $CODEC{'bframes'};
        }
        if ($CODEC{'wpred'} != -1) {
                $WPRED = $CODEC{'wpred'};
        }
        if ($CODEC{'bpyramid'} != -1) {
                $BPYRAMID = $CODEC{'bpyramid'};
        }
        if ($CODEC{'refs'} != -1) {
                $REFS = $CODEC{'refs'};
        }
        if ($CODEC{'mixed_refs'} != -1) {
                $MIXEDREFS = $CODEC{'mixed_refs'};
        }
        if ($CODEC{'fastpskip'} != -1) {
                $FPSKIP = $CODEC{'fastpskip'};
        }
        if ($CODEC{'dctdec'} != -1) {
                $DCTDEC = $CODEC{'dctdec'};
        }
        if ($CRF <= 0 && $CODEC{'crf'} != -1) {
                $CRF = $CODEC{'crf'};
        }
        if ($CODEC{'qp'} != -1) {
                $QP = $CODEC{'qp'};
        }
        if ($CODEC{'psyrd'} != -1) {
                $PSYRD = $CODEC{'psyrd'};
        }
        if ($CODEC{'trellis'} != -1) {
                $TRELLIS = $CODEC{'trellis'};
        }
        if ($CODEC{'aq'} != -1) {
                $AQ = $CODEC{'aq'};
        }
        if ($CODEC{'aqstrength'} != -1) {
                $AQSTRENGTH = $CODEC{'aqstrength'};
        }
        if ($CODEC{'deblock'} != -1) {
                $DEBLOCK = $CODEC{'deblock'};
        }
        if ($CODEC{'deinterlace'} != -1) {
                $DEINTERLACE = $CODEC{'deinterlace'};
        }
        if ($CODEC{'interlace'} != -1) {
                $INTERLACE = $CODEC{'interlace'};
        }
        if ($CODEC{'nr'} != -1) {
                $NR = $CODEC{'nr'};
        }
        if ($CODEC{'ssim'} != -1) {
                $SSIM = $CODEC{'ssim'};
        }
        if ($CODEC{'psnr'} != -1) {
                $PSNR = $CODEC{'psnr'};
        }
        if (!$USE_MENCODER && !$USE_FFMPEG && $CODEC{'ngtc'} != -1) {
                $USE_DECODEAV = $CODEC{'ngtc'};
        }
        if (!$USE_MENCODER && !$USE_DECODEAV && $CODEC{'ffmpeg'} != -1) {
                $USE_FFMPEG = $CODEC{'ffmpeg'};
        }
        if ($CODEC{'aac'} != -1) {
		if ($CODEC{'aac'} eq "nero") {
			$AACENC = $NERO;
			$AUDIO_USE_WAV = 1;
		} elsif ($CODEC{'aac'} eq "faac") {
			$AACENC = $FAAC;
		}
        }

	# Bitrates
	if ($VBRATE) {
        	$VBRATE = $VBRATE / 1000;
        	$VBRATE =~ s/\..*$//g;
	}
	if ($MAXRATE) {
        	$MAXRATE = $MAXRATE / 1000;
        	$MAXRATE =~ s/\..*$//g;
	}
	if ($BUFSIZE) {
        	$BUFSIZE = $BUFSIZE / 1000;
        	$BUFSIZE =~ s/\..*$//g;
	}
        $ABRATE = $ABRATE / 1000;
        $ABRATE =~ s/\..*$//g;

	# Make sure framesize is divisible by 2 for x264
	if ($FSIZE) {
		my ($WD, $HT) = split(/x/, $FSIZE);

		if ($MAXWIDTH > 0) {
			my $new_fsize;
			if (($new_fsize = scale_to_width($WD, $HT, $MAXWIDTH))) {
				$FSIZE = $new_fsize;
				($WD, $HT) = split(/x/, $FSIZE);
			}
		}

        	if ($WD%16 != 0) {
                	$WD = ($WD+(16-($WD%16)));
        	}
        	if ($HT%16 != 0) {
                	$HT = ($HT+(16-($HT%16)));
        	}
		$FSIZE = $WD . "x" . $HT;
	}	

	# Aspect DAR and SAR calculations
        if(!$ASPECT && $ORIG_ASPECT) {
		# Use input DAR
		$ASPECT = $ORIG_ASPECT;

		# Autocalculate SAR
		if ($FSIZE) {
			if ($ASPECT =~ /^\d+\.\d+$/ || $ASPECT =~ /^\d+$/) {
				$SAR = calc_sar("$ASPECT:1", $FSIZE);
			} else {
				$SAR = calc_sar("$ASPECT", $FSIZE);
			}
			if ($SAR !~ /^\d+:\d+$/) {
				$SAR = "";
			}
		}
	} elsif ($ASPECT && !$SAR && $FSIZE) {
		# Autocalculate SAR
		if ($ASPECT =~ /^\d+\.\d+/ || $ASPECT =~ /\d+/) {
			$SAR = calc_sar("$ASPECT:1", $FSIZE);
		} else {
			$SAR = calc_sar("$ASPECT", $FSIZE);
		}
		if ($SAR !~ /^\d+:\d+$/) {
			$SAR = "";
		}
	}

	if ($ASPECT) {
		$RAWVIDOPTS.= "-aspect " . $ASPECT . " ";
	}
	if ($DEINTERLACE) {
		if ($USE_FFMPEG) {
			$RAWVIDOPTS.= "-deinterlace ";
		}
	}

	if ($SPLIT_SECS) {
		$MUXOPTS = "-split $SPLIT_SECS ";
	}

	return;
}

# Scale to maxwidth
sub scale_to_width {
	my $orig_width = shift;
	my $orig_height = shift;
	my $scale_width = shift;
	my $new_frame_size = "";
	my $new_height;

        if ($orig_width > $scale_width) {
                $new_height = $scale_width * ($orig_height/$orig_width);
                $new_height =~ s/\..*$//g;
                $new_frame_size = $scale_width . "x" . $new_height;
		if ($VERB >= 0) {
                	print CONSOLE_OUTPUT "[$count] Scaling Width/Height to " . $new_frame_size . "\n";
		}
        }
	return $new_frame_size;
}

# Check/calculate GOP Size
sub check_gop {
	my $gop = shift;
	my $maxgop = shift;
	my $fps = shift;
	my $tmpfps = $fps;
	my $mingop;

        if ($fps =~ /\//) {
                my ($r, $d) = split (/\//, $fps);
                $tmpfps = ($r/$d);
        }

	# Find right GOP Size
        my $FPS_TEST = roundup(($maxgop * $tmpfps));
        $FPS_TEST =~ s/\.\d+$//g;

        # Maximum IDR Frame Interval
        if ($gop > $FPS_TEST) {
                $gop = $FPS_TEST;
		if ($VERB >= 0) {
                	print CONSOLE_OUTPUT "[$count] Lowering GOP size to " . $gop . "\n";
		}
        }

        # Minimum IDR Frame Interval
        $mingop = roundup($tmpfps);
        $mingop =~ s/\.\d+$//g;
	if ($mingop > $gop) {
		$mingop = $gop;
	}
        if ($mingop < 2) {
                $mingop = 2;
        }
	if ($VERB > 0) {
               	print CONSOLE_OUTPUT "[$count] Setting MIN GOP size to " . $mingop . "\n";
	}
	return ($gop,$mingop);
}

# Calculate SAR
sub calc_sar {
	my $dar = shift;
	my $framesize = shift;
	my $sar = 0;
	my $div = 0;

	my ($WD, $HT) = split(/x/, $framesize);
	my ($ix, $iy) = split(/:/, $dar);

	my $v = $ix * $HT;
	my $w = $iy * $WD;
	$v = roundup($v);
	$w = roundup($w);
	if ($v == $w) {
		return "1:1";
	}
	if ($w > $v) {
		$div = $w - $v;
	} else {
		$div = $v - $w;
	}
	my $x = $w/$div;
	my $y = $v/$div;
	if ($x > 0 && $y > 0) {
		$sar = roundup($y) . ":" . roundup($x);
	}

	return $sar;
}

# Setup X264 Command Line/Settings
sub setup_x264 {
	$X264OPTS = "";

	# Profiles
	if ($PROFILE eq "high") {
		$DCT8x8 = 1;
	} elsif ($PROFILE eq "main") {
		$DCT8x8 = 0;
	} elsif ($PROFILE eq "baseline") {
		$DCT8x8 = 0;
		$BF = 0;
		$CABAC = 0;
	} else {
		# Default to High Profile
		$DCT8x8 = 1;
	}

	# Partitions
	if (!$PARTITIONS) {
		$PARTITIONS =   "p8x8,b8x8,i8x8,i4x4";
	}

	# Verbosity
	if ($VERB <= 0) {
		$X264OPTS.= "--quiet ";
	} elsif ($VERB > 3) {
		$X264OPTS.= "--progress ";
	}

	# Stats
	if (!$PSNR) {
		$X264OPTS.= "--no-psnr ";
	}
	if (!$SSIM) {
		$X264OPTS.= "--no-ssim ";
	}

	# H264 Encoding Settings
	if ($LEVEL) {
		$X264OPTS.= "--level $LEVEL ";
	}
	if (!$DCTDEC) {
		$X264OPTS.= "--no-dct-decimate ";
	}
	if (!$MECHROMA) {
		$X264OPTS.= "--no-chroma-me ";
	}
	if (!$FPSKIP) {
		$X264OPTS.= "--no-fast-pskip ";
	}
	if ($DCT8x8) {
		$X264OPTS.= "--8x8dct ";
	}
	if ($AUD) {
		$X264OPTS.= "--aud ";
	}
	if ($REFS && $MIXEDREFS) {
		$X264OPTS.= "--mixed-refs ";
	}
	if (!$CABAC) {
		$X264OPTS.= "--no-cabac ";
	}
	if ($BF && $BADAPT != 1) {
		$X264OPTS.= "--b-adapt $BADAPT ";
	}
	if ($BF && $WPRED) {
		$X264OPTS.= "--weightb ";
	}
	if ($BF && $BPYRAMID) {
		$X264OPTS.= "--b-pyramid ";
	}
	if ($CRF) {
		$X264OPTS.= "--crf $CRF ";
	} elsif ($QP > -1) {
		$X264OPTS.= "--qp $QP ";
	} elsif ($VBRATE) {
		$X264OPTS.= "--bitrate $VBRATE ";
		if ($MAXRATE && $BUFSIZE) {
			$X264OPTS.= "--vbv-maxrate $MAXRATE ";
			$X264OPTS.= "--vbv-bufsize $BUFSIZE ";
		}
	} else {
		# Failed since no rate control defined
		if (!$NOVIDEO) {
			print CONSOLE_OUTPUT "ERROR: No valid bitrate or crf specified.\n";
			return 1;
		}
	}
	if ($NR) {
		$X264OPTS.= "--nr $NR ";
	}
	if ($INTERLACE) {
		$X264OPTS.= "--interlaced ";
	}
	if ($AQ > -1 && $AQSTRENGTH > -1) {
		$X264OPTS.= "--aq-mode $AQ --aq-strength $AQSTRENGTH ";
	}
	if ($DEBLOCK =~ /^\d+:\d+$/) {
		$X264OPTS.= "--deblock $DEBLOCK ";
	} else {
		$X264OPTS.= "--no-deblock ";
	}
	if ($OFPS) {
		$X264OPTS.= "--fps $OFPS ";
	}
	if ($THREADS) {
		$X264OPTS.= "--threads $THREADS ";
	}
	if ($SAR) {
		$X264OPTS.= "--sar $SAR ";
	}
	if ($MINGOP) {
		$X264OPTS.= "--min-keyint $MINGOP ";
	}
	if ($VIDEO_USE_Y4M) {
		$X264OPTS.= "--y4m-input ";
	}

	$X264OPTS.= "--trellis $TRELLIS --subme $SUBME --direct $DIRECT --psy-rd $PSYRD -r $REFS --me $ME ";
	$X264OPTS.= "--partitions \"$PARTITIONS\" --bframes $BF --keyint $GOP --merange $MERANGE --qcomp $QCOMP";

	return 0;
}

# Default Codec Settings
sub default_codec {
	# Raw Audio/Video Settings
	$OFPS = 	"-1"; 		# FPS
	$FSIZE = 	"-1";		# HxW
	$MAXWIDTH =	"-1";
	$VBRATE = 	 0;		# Video Kbit
	$MAXRATE =	"0";
	$BUFSIZE =	"0";
	$ABRATE = 	"-1";		# Audio Kbit
	$ARATE = 	"-1";		# Audio Rate hz
	$ACHAN = 	"-1";		# mono/stereo

	# Mplayer Scaling
	$SWS =		"9";

	# x264 Encoding Settings
	$PROFILE =	"0";
	$LEVEL =	"0";
	$GOP =		"300";
	$ME =		"hex";
	$MECHROMA =	"1";
	$MERANGE =	"16";
	$DIRECT =	"auto";
	$SUBME =	"6";
	$QCOMP =	"0.60";
	$CABAC =	"1";
	$BF =		"16";
	$BADAPT =	"1";
	$WPRED =	"0";
	$BPYRAMID =	"1";
	$REFS =		"4";
	$MIXEDREFS =	"1";
	$FPSKIP =	"0";
	$DCTDEC =	"0";
	$CRF =		0;
	$QP =		"-1";
	$PSYRD =	"1.0:0.0";
	$TRELLIS =	"1";
	$AQ =		"1";
	$AQSTRENGTH =	"1.0";
	$DEBLOCK =	"0:0";
	$DEINTERLACE =	"0";
	$INTERLACE = 	"0";
	$NR =		"0";
	$SSIM =		"1";
	$PSNR =		"0";
	$MINGOP =	"8";
	$MAXGOP =	"10";
	$THREADS =	"auto";
	$PARTITIONS = 	"p8x8,b8x8,i8x8,i4x4";
	$DCT8x8 =	"1";
	$AUD =		"1";
}

# Read Codec File
sub read_codec {
	my $CODEC_FILE = shift;

	#Default Codec
	%CODEC = (
                        inputformat => -1,
			autoconf => -1,
                        sync => -1,
                        precheck => -1,
                        profile => -1,
                        level => -1,
                        sar => -1,
                        aspect => -1,
                        framerate => -1,
                        framesize => -1,
			maxwidth => -1,
                        gopsize => -1,
                        bitrate => -1,
                        maxrate => -1,
                        bufsize => -1,
                        audiorate => -1,
                        abitrate => -1,
                        channels => -1,
                        me_method => -1,
                        me_chroma => -1,
                        me_range => -1,
                        directpred => -1,
			partitions => -1,
                        subq => -1,
                        qcomp => -1,
                        cabac => -1,
                        bframes => -1,
			badapt => -1,
                        wpred => -1,
                        bpyramid => -1,
                        refs => -1,
                        mixed_refs => -1,
                        fastpskip => -1,
                        dctdec => -1,
                        crf => -1,
                        qp => -1,
                        psyrd => -1,
                        trellis => -1,
                        aq => -1,
                        aqstrength => -1,
                        deblock => -1,
                        deinterlace => -1,
                        interlace => -1,
                        nr => -1,
                        ssim => -1,
                        psnr => -1,
                        debug => -1,
                        ffmpeg => -1,
			ngtc => -1,
                        aac => -1,
			nop => -1
	);

        if (-f "$CODEC_FILE") {

                require "$CODEC_FILE";

                while ( my ($key, $value) = each(%CODEC) ) {
			if (!$key) {
				break;
			}
                        while ( my ($newkey, $newvalue) = each(%INPUT_CODEC) ) {
                                if ($key eq $newkey) {
                                        $CODEC{$key} = $newvalue;
                                        $value = $newvalue;
                                        break;
                                }
				if (!$key) {
					break;
				}
                        }
                }
        } else {
                print CONSOLE_OUTPUT "WARNING: CODEC File $CODEC_FILE Not Found!\n";
        }

	# Setup DEBUG Level from codec config
        if ($CODEC{'debug'} != -1) {
                my $V = $CODEC{'debug'};
		for(my $i = 0; $i < $V; $i++) {
			push(@VERBOSE, "1");
		}
        }
}

sub show_codec {
	print "%INPUT_CODEC = (\n";
	while ( my ($key, $value) = each(%CODEC) ) {
		if (!$key) {
			break;
		}
		if ($key ne "nop") {
			printf("\t%-20s%s,\n", $key, "=> \"" . $value . "\"");
		}
        }
	print ");\n";
}

# Get input file information with mplayer
sub get_file_info {
	my $file = shift;

        if ($CODEC{'precheck'} != -1) {
                $PRECHECK = $CODEC{'precheck'};
        }
        if ($CODEC{'autoconf'} != -1) {
                $AUTOCONF = $CODEC{'autoconf'};
        }

	if (! -f $file) {
		return 1;
	}

	if (! -f $MEDIAINFO || (!$PRECHECK && !$AUTOCONF)) {
		return 0;
	}

	# Get Media file information
 	my $mi_video = "--Inform=\"Video;%DisplayAspectRatio%,%PixelAspectRatio%,%FrameRate%,%Height%,%Width%,%BitRate%,%Duration%\"";
 	my $mi_audio = "--Inform=\"Audio;%Video_Delay%,%BitRate%,%SamplingRate%,%Channels%\"";
	my $vinfo = `$MEDIAINFO $mi_video $file`;
	my $ainfo = `$MEDIAINFO $mi_audio $file`;
	chomp($vinfo);
	chomp($ainfo);

	($ORIG_ASPECT, $ORIG_PAR, $ORIG_FRAMERATE, $ORIG_HEIGHT, $ORIG_WIDTH, $ORIG_BITRATE, $ORIG_LENGTH) =
		split(/,/, $vinfo);
	($ORIG_VDELAY, $ORIG_AUDIO_BITRATE, $ORIG_AUDIO_RATE, $ORIG_AUDIO_NCH) =
		split(/,/, $ainfo);

        # Output File Information
        if ($VERB >= 0) {
                print CONSOLE_OUTPUT "\nINPUT FILE: " . $file . "\n";
		if (!$NOVIDEO) {
                	print CONSOLE_OUTPUT "VIDEO INFO: FPS(" . $ORIG_FRAMERATE . ") WxH(" . $ORIG_WIDTH . "x" .
                        	$ORIG_HEIGHT . ") DAR(" . $ORIG_ASPECT . ") BPS(" . $ORIG_BITRATE .  ") LENGTH(" . $ORIG_LENGTH . ")\n";
		}
		if (!$NOAUDIO) {
                	print CONSOLE_OUTPUT "AUDIO INFO: RATE(" . $ORIG_AUDIO_RATE . ") BPS(" .
                        	$ORIG_AUDIO_BITRATE . ") CHANNELS(" . $ORIG_AUDIO_NCH . ") DELAY(" . $ORIG_VDELAY . ")\n";
		}
		print CONSOLE_OUTPUT "\n";
        }

	return 0;
}

sub show_enc_settings {
        # Output File Information
        if ($VERB >= 0) {
                print CONSOLE_OUTPUT "\nOUTPUT FILE: " . $OUTPUT_FILE . "\n";
		if (!$NOVIDEO) {
                	print CONSOLE_OUTPUT "VIDEO INFO: FPS(" . $OFPS . ") WxH(" . $FSIZE
                        	. ") DAR(" . $SAR . ") BPS(" . $VBRATE .  ") CRF(" . $CRF . ")\n";
		}
		if (!$NOAUDIO) {
                	print CONSOLE_OUTPUT "AUDIO INFO: RATE(" . $ARATE . ") BPS(" .
                        	$ABRATE . ") CHANNELS(" . $ACHAN . ")\n";
		}
		print CONSOLE_OUTPUT "\n";
        }
}

# Cleanup at end
sub cleanup {
	# Remove fifo's
	if (!$RAW_VIDEO_INPUT) {
		if (-p $RAW_VIDEO_FIFO || -f $RAW_VIDEO_FIFO) {
			unlink($RAW_VIDEO_FIFO);
		}
	}
	if (!$RAW_AUDIO_INPUT) {
		if (-p $RAW_AUDIO_FIFO || -f $RAW_AUDIO_FIFO) {
			unlink($RAW_AUDIO_FIFO);
		}
	}

	# Remove Encodings if left for some odd reason
	if (-f $COMP_VIDEO_FIFO) {
		unlink($COMP_VIDEO_FIFO);
	}
	if (-f $COMP_AUDIO_FIFO) {
		unlink($COMP_AUDIO_FIFO);
	}

	# Remove tmp streams
	foreach(@streams) {
		if (-f $_) {
			unlink($_);
		}
	}
	@streams = ();

	# Remove or save Log Files
	if ($LOGFILES && !$KEEPLOGFILES) {
		if (-f $RAW_VIDEO_LOG) {
			unlink($RAW_VIDEO_LOG);
		}
		if (-f $RAW_AUDIO_LOG) {
			unlink($RAW_AUDIO_LOG);
		}
		if (-f $COMP_VIDEO_LOG) {
			unlink($COMP_VIDEO_LOG);
		}
		if (-f $COMP_AUDIO_LOG) {
			unlink($COMP_AUDIO_LOG);
		}
		if (-f $MUXER_LOG) {
			unlink($MUXER_LOG);
		}
		if (-f $MAIN_LOG) {
			unlink($MAIN_LOG);
		}
	} elsif ($LOGFILES && $KEEPLOGFILES) {
		move($RAW_VIDEO_LOG, $OUTPUT_FILE . "-vdec.log") or print CONSOLE_OUTPUT (qq{failed to move $RAW_VIDEO_LOG -> $OUTPUT_FILE-vdec.log \n});
		move($COMP_VIDEO_LOG, $OUTPUT_FILE . "-venc.log") or print CONSOLE_OUTPUT (qq{failed to move $COMP_VIDEO_LOG -> $OUTPUT_FILE-venc.log \n});
		move($RAW_AUDIO_LOG, $OUTPUT_FILE . "-adec.log") or print CONSOLE_OUTPUT (qq{failed to move $RAW_AUDIO_LOG -> $OUTPUT_FILE-adec.log \n});
		move($COMP_AUDIO_LOG, $OUTPUT_FILE . "-aenc.log") or print CONSOLE_OUTPUT (qq{failed to move $COMP_AUDIO_LOG -> $OUTPUT_FILE-aenc.log \n});
		move($MUXER_LOG, $OUTPUT_FILE . "-avmux.log") or print CONSOLE_OUTPUT (qq{failed to move $MUXER_LOG -> $OUTPUT_FILE-avmux.log \n});
		move($MAIN_LOG, $OUTPUT_FILE . ".log") or print CONSOLE_OUTPUT (qq{failed to move $MAIN_LOG -> $OUTPUT_FILE.log \n});

		if ($VERB > 0) {
			print CONSOLE_OUTPUT "Saved log files for $OUTPUT_FILE:\n\n";	
			print CONSOLE_OUTPUT " [Main Program]  * $OUTPUT_FILE.log\n";
			print CONSOLE_OUTPUT " [A/V MP4 Muxer] * $OUTPUT_FILE-avmux.log\n";
			print CONSOLE_OUTPUT " [Audio Decoder] * $OUTPUT_FILE-adec.log\n";
			print CONSOLE_OUTPUT " [Audio Encoder] * $OUTPUT_FILE-aenc.log\n";
			print CONSOLE_OUTPUT " [Video Decoder] * $OUTPUT_FILE-vdec.log\n";
			print CONSOLE_OUTPUT " [Video Encoder] * $OUTPUT_FILE-venc.log\n\n";
		}
	}

	# Wait for any remaining Children Processes
	my $num_children = scalar(@children);
	if ($VERB > 0) {
		print CONSOLE_OUTPUT "Spawned $num_children Children from Parent process [$$]:\n\n";
	}
	for(my $i = 0; $i < $num_children; $i++) {	
		if (!$children[$i]{'pid'}) {
			return;
		}
		if ($VERB > 0) {
			printf(CONSOLE_OUTPUT " (%d) Child \"%s\" with pid [%d] file \"%s\" status \"%s\".\n", 
				($i+1), $children[$i]{'name'}, $children[$i]{'pid'}, $children[$i]{'file'}, $children[$i]{'status'});
		}
		wait_for_pid($children[$i]{'pid'}, $children[$i]{'name'}, $children[$i]{'file'}, 10, 1)
	}
}


