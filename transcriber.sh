#!/bin/bash
# vim: ts=2 sw=2
#
#       A cron job script for transcribing audio and sorting files
#
#
#       This is intended to be run from cron every 5 min
#
#
#  Copyright (C) 2020 Bryan Fields
#  bryan@bryanfields.net
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License along
#  with this program; if not, write to the Free Software Foundation, Inc.,
#  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
#--------------------------- Revision History ----------------------------------
#  2025-02-15   bfields inital prototype
#  2025-02-17   numerious bugfixes inital git commit
#

#How to use
# bash ./transcriber.sh /path/to/base-dir

# set bash options
#set -e
#shopt -s lastpipe

# variables 
#BASEDIR='/home/svar/rec/top-right'
BASEDIR="$1"
#largest size, 25mib

LSIZE='26214400'
#the smallest size file we will transcribe 
#8000 Samples * 2 bytes per sample = 16000 bytes/s = 10 sec of dead error for each, plus 4 seconds = 224000 bytes
SSIZE='224000'
#Open AI token
OPENAITOKEN='AITOKEN'
TEMPDIR="${BASEDIR}/tmp"
ERRDIR="${BASEDIR}/errors"
PIDFILE="${TEMPDIR}/transcriber.pid"
#must end in .ogg
OGGTEMP="${TEMPDIR}/ogg.tmp.ogg"
JSON="${TEMPDIR}/json.tmp"
TEXTTEMP="${TEMPDIR}/tmp.txt"
GLOB="*.wav"

function PID {

	if test -d $TEMPDIR
        then
               	#echo "Temp Dir $TEMPDIR is present"
               	:
        else
               	mkdir -p $TEMPDIR && echo "Temp Directory $TEMPDIR Created"
        fi


	if [ -f $PIDFILE ]
	then


		PID=$(cat $PIDFILE)
		ps -p $PID > /dev/null 2>&1
	      	if [ $? -eq 0 ]
	      	then
			echo "Process already running"
		      	exit 1
	      	else
		## Process not found assume not running
			echo $$ > $PIDFILE
		    	if [ $? -ne 0 ]
		    	then
			  	echo "Could not create PID file"
				exit 1
			fi
		fi
	else
		echo $$ > $PIDFILE
		if [ $? -ne 0 ]
		then
			echo "Could not create PID file"
			exit 1
		fi
	fi

}

function CHECK_FILE {
	
	# $1 is the file we are checking

	#returncodes
	# 0 all good trasnscribe it
	# 5 too small, move it but don't trasnscribe it
	#10 wavefile size error in header
	#20 wavefile corrupt header 
	
	fsize=`stat -c %s $1`
	# detect the file starts with RIFF 0x52494646
	magic=`od  --endian=big -tx4 -A none -j 0 -N4 $1`
	local returncode='0'
	if [ $magic -eq '52494646' ]
	then 
		#echo "it's equal" 
		:
	else 
		#echo "nope" 
		returncode='20'
		return ${returncode}
	fi

	# detect size
	wavsize="$((16#$(echo `od  --endian=little -tx4 -A none -j 4 -N4 $1 | tr -d ' '`)))"
	# the wavsize will be 8 less than the fsize
	if [ $fsize -eq $(($wavsize+8)) ] && [ $magic -eq '52494646' ] 
	then 
		#echo "it's good size"   
		:
	else 
		#echo "bad file" 
		returncode='10'
		return ${returncode}
      	fi

	if [ $fsize -ge ${SSIZE} ] && [ $fsize -eq $(($wavsize+8)) ] && [ $magic -eq '52494646' ]
	then 
		#echo "it's larger than ${SSIZE}"  
		:
	else 
		#echo "file to small" 
		returncode=5
		return ${returncode}
	fi
	#echo "returncode is ${returncode}"
	return ${returncode}
}

function FILENAME {

	#get the date 2025-02-04
	BASENAME=${1##*/}
	BASENAME=${BASENAME%.*}
	DATE=`echo $BASENAME | grep -Eo '[[:digit:]]{4}-[[:digit:]]{2}-[[:digit:]]{2}'`
	YEAR=`echo ${DATE} | cut --delimiter='-' --fields=1`
	MONTH=`echo ${DATE} | cut --delimiter='-' --fields=2`
	DAY=`echo ${DATE} | cut --delimiter='-' --fields=3`
	# get the TL part
	PREFIX=`echo $BASENAME |  cut --delimiter='-' --fields=1`
	#get the TIME in HHMM.SS
	TIME=`echo $BASENAME |  cut --delimiter='-' --fields=5 | cut --delimiter='.' --fields=1,2`
}

function OGGIFY {
	# here we convert it to OGG and check that it's under LSIZE
	nice -n15 opusenc  --speech --bitrate 24k $1 ${OGGTEMP}
	oggsize=`stat -c %s ${OGGTEMP}`
	if [[ $((oggsize)) -le $((LSIZE)) ]]
       	then 
		#echo "oggfile smaller than ${LSIZE} bytes" 
		:
       	else 
		#echo "ogg file to big" 
		returncode="25"
	fi
	return ${returncode}

}

function DIRVERIFY {
	# Test that the error DIR is there
	if test -d $ERRDIR
	then
		#echo "Temp Dir $ERRDIR is present"
		:
	else 
		mkdir -p $ERRDIR && echo "Temp Directory $ERRDIR Created"
	fi

	# check that the directory exists based on FILENAME function output
	if test -d ${BASEDIR}/${YEAR}/${MONTH}/${DAY} 
	then 
		#echo "Directory ${BASEDIR}/${YEAR}/${MONTH}/${DAY} exists."
		:
	else 
		mkdir -p ${BASEDIR}/${YEAR}/${MONTH}/${DAY} && echo "Directory ${BASEDIR}/${YEAR}/${MONTH}/${DAY} created"
	fi
}

function TRANSCRIBE {
	curl "https://api.openai.com/v1/audio/transcriptions" \
		-H "Authorization: Bearer ${OPENAITOKEN}" \
		-H "Content-Type: multipart/form-data" \
		-F file="@${OGGTEMP}"  \
		-F model="whisper-1" \
		-F response_format="verbose_json" \
		-F "timestamp_granularities[]=segment" > ${JSON}
}

function TEXTIFY {
	# convert the json into usable text
	jq -r '
def pad2: if . < 10 then "0" + tostring else tostring end;

.segments[] |
 ((.start / 3600 | floor | pad2) + ":" +
 (((.start % 3600) / 60 | floor) | pad2) + ":" +
 ((.start % 60 | pad2 ))
)  + "  " +     .text' ${JSON} > ${TEXTTEMP}
}




#OK put it all together
PID
#test if glob exists
if ls ${BASEDIR}/current/${GLOB} &> /dev/null
then 
	for i in ${BASEDIR}/current/${GLOB}  
	do
		echo "working on top of file $i"
		FILENAME $i
		DIRVERIFY 
		CHECK_FILE $i 
		CKEXIT=$?
		if [ $CKEXIT -eq '5' ] 
		then
			echo "File $i is too small"
			OGGIFY $i
			mv ${OGGTEMP} "${BASEDIR}/${YEAR}/${MONTH}/${DAY}/${BASENAME}.ogg"
			rm $i
			continue 1

		elif [ $CKEXIT -eq '10' ]
		then
			#check if the file is being written too s for silent
			fuser -s $i 
			fuserexit=$?
			if [ $fuserexit -eq '0' ]
			then
				echo "Wavefile $i still open for writing"
			else
				echo "Wavefile size error in header of $i moving to ${ERRDIR}"
				mv $i ${ERRDIR}
			fi
			continue  1

		elif [ $CKEXIT -eq '20' ]
		then
			echo "Wavefile magic error: $i moving to ${ERRDIR}"
			mv $i ${ERRDIR}
			continue  1
		fi
		CKEXIT='0'
		#Convert the File to OGG, check that it's under 25 meg (2:22.22)
		OGGIFY $i
		CKEXIT=$?
		if [ $CKEXIT -eq '25' ]
		then
			echo "oggfile ${BASENAME}.ogg larger than ${LSIZE} bytes; will not be transcribed"
			mv ${OGGTEMP} "${BASEDIR}/${YEAR}/${MONTH}/${DAY}/${BASENAME}.ogg" 
		elif [ $CKEXIT -eq '0' ]
		then
			echo "TRANSCRIBE and TEXTIFY $i"
			TRANSCRIBE
			TEXTIFY
			mv ${OGGTEMP} "${BASEDIR}/${YEAR}/${MONTH}/${DAY}/${BASENAME}.ogg"
			mv ${TEXTTEMP} "${BASEDIR}/${YEAR}/${MONTH}/${DAY}/${BASENAME}.txt"
			mv ${JSON} "${BASEDIR}/${YEAR}/${MONTH}/${DAY}/${BASENAME}.json"
			rm "$i"
		elif [ $CKEXIT -ne '0' ] 
		then
			echo "Unknown error during OGGification"
		fi

	done
	echo "processed all files in ${BASEDIR}/current/"
	rm $PIDFILE

else
	echo "${BASEDIR}/current/${GLOB} doesn't exist"
	exit 255
fi


#exit
