x264transcoder
==============

x264 Transcoder

Version 0.0.6 by Chris Kennedy (C) 2009

./x264transcoder.pl Usage:
        -h -help                        Help
        -i -input <file>                Input file name, can be specified multiple times
        -vi -videoinput <file>          Raw Video Input file name
        -ai -audioinput <file>          Raw Audio Input file name
        -o -output <file>               Output file name
        -test                           Test run, don't actually run commands
        -sc -showcodec                  Show Codec configuration file
        -l -log                         Keep log files and save with output file
        -t -time <secs>                 Length in seconds to encode
        -a -autoconf [0|1]              Use video/audio settings from source video
        -mw -maxwidth <width>           Maximum width, scale to this size
        -sws <0-10>                     Mplayer/Mencoder software scaling method, 0=low q 10=best
        -apl -audiopreload <ms>         Mplayer/Mencoder audio ms to preload, default 0.0
        -pc -precheck                   Get file information to use if no bitrate/framesize/fps set
        -if -infmt                      Input format string for decoder if using raw yuv/pcm files
        -na -noaudio                    No Audio input/output
        -nv -novideo                    No Video input/output
        -sync                           Find if an Audio/Video delay exist and sync streams
        -newsync                        Audio/Video delay value, don't use av offset from original file
        -async                          Pass Audio sync option value to ffmpeg/mencoder decoder
        -vsync                          Pass Video sync option value to ffmpeg/mencoder decoder
        -ngtc                           Use ngtc as decoder for audio/video
        -ffmpeg                         Use FFMPEG as decoder for audio/video
        -noffmpeg                       Don't Use FFMPEG as decoder for audio/video
        -oldffmpeg                      Use Older FFMPEG as decoder for audio/video
        -x -demux                       Save demuxed raw Audio/Video streams
        -v -verbose                     Increase verbosity per -v
        -y -overwrite                   Overwrite output file if it exists
        -c -codec <file>                Codec file to use for encoding settings
        -b -bitrate <bps>               Bitrate in bps (1000000 = 1Mbit)
        -ab -abitrate <bps>             Audio Bitrate in bps (128000 = 128kbit)
        -ar -arate <rate>               Audio sample rate in khz (44100 = 44.1khz)
        -ac -achan <channels>           Audio channels
        -r -ofps <framerate>            Video Framerate, FPS of output video
        -s -framesize <HxW>             Video Framesize of output video HxW
        -crf <1-51>                     CRF or constant rate factor, quantization average
        -lvl -level <1-5>               H.264 Level for hardware devices, not usually needed
        -pf -profile <type>             Profile type, baseline|main|high, H.264 specs
        -d -directory <dir>             Directory to scan for files
        -p -pattern <regexp>            File Pattern to look for in scan directory
        -ss -segsecs <seconds>          Output file segments length in seconds
        -asr -aspect <int:int>          Aspect Ratio
        -sar <int:int>                  Source Aspect Ratio
        -aac -aacenc [nero|faac]        Choose either FAAC or NERO for AAC Audio Encoding
        -wav -usewav                    Use wav format for audio pcm samples
        -y4m -usey4m                    Use Y4M format for video yuv samples
        -fd -fpsdiff <float>            FPS add/sub amount when Muxing Raw video, for sync problems
        -e -enc <fmt:vcodec:acodec>     Encode using ffmpeg

