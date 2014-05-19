:

#     snap is a utility to store some directories on a server, versioned.
#
# Copyright (C) 2014, Human Rights Data Analysis Group (HRDAG)
#     https://hrdag.org
#
# This file is part of snap.
#
# snap is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# snap is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with snap.  If not, see <http://www.gnu.org/licenses/>.

Version=0.2.9

set -u					# error if expand unset variable

umask 02				# we use group perms

Run=					# caller can set (e.g. with getopts d)

# ----------------------------------------------------------------------------
# constants
# ----------------------------------------------------------------------------

# the emacs temps in the --exclude patterns are duplicated in write_metadata
readonly rsync_opts="--verbose --compress-level=9 --partial \
	   --recursive --links --hard-links --times --sparse --omit-dir-times
	   --exclude=*~ --exclude=#*# --exclude=.#*"
# --server options that correspond to client's use of $rsync_opts;
#    -O is not used when --sender
readonly rsync_server_opts="-vlOHtrSze.iLs --compress-level=9 --partial"

readonly snappable_subdirs="input output frozen"

readonly true=t false=

readonly tmpdir=/tmp/$(id -nu); mkdir -m 0700 -p $tmpdir
our_name=${0##*/}			# caller can change this
readonly   _tmp=$tmpdir/$our_name.$$	# reserved for snaplib.sh
readonly  tmp_1=$tmpdir/$our_name-1.$$
readonly  tmp_2=$tmpdir/$our_name-2.$$
readonly  tmp_3=$tmpdir/$our_name-3.$$
readonly  tmp_4=$tmpdir/$our_name-4.$$
readonly  tmp_5=$tmpdir/$our_name-5.$$
readonly  tmp_files="$_tmp $tmp_1 $tmp_2 $tmp_3 $tmp_4 $tmp_5"

readonly date=$(date '+%a %m/%d %X %Z')

# ----------------------------------------------------------------------------
# generic helper functions
# ----------------------------------------------------------------------------

have_cmd() { type -t "$@" &> /dev/null; }
run_cmd () { $Run "$@" || error "$* => $?"; }

warn () { echo -e "\n$our_name: $*\n" >&2; have_cmd log && log "$@";return 1; }
error() { warn "$*"; exit 1; }

cd_() { cd "$@" || error "cd => $?"; }

# ----------------------------------------------------------------------------

print_or_egrep_Usage_then_exit() {
	[[ ${1-} == -[hHk] ]] && shift	# strip help or keyword-search option
	[[ $# == 0 ]] && echo -e "$Usage" && exit 0
	echo "$Usage" | grep -i "$@"
	exit 0
}

# ----------------------------------------------------------------------------
# functions used by snap and snapserv
# ----------------------------------------------------------------------------

# convert_snap_metadata assumes that .snap.sha1 is renamed last
readonly old_name__new_name__pairs="
.snap.config		.snap/config
.snap.log		.snap/push.log
.snap.rev		.snap/revision
.snap.rm		.snap/paths-to-delete
.snap.pre-push		.snap/files-pre-push
.snap.local		.snap/files-local
.snap.local.sha1	.snap/files-local.sha1
.snap.orig		.snap/files-repo
.snap.sha1		.snap/files-repo.sha1

.snap/config		.snap/config.sh
"

convert_snap_metadata() {
	[[ $old_name__new_name__pairs ]] || return 1
	[[ -f .snap.sha1 || -f .snap/config ]] || return 1 # already converted?

	[[ -f .snap ]] && run_cmd mv .snap .snap.orig
	run_cmd mkdir -p .snap
	local      old_name  new_name
	echo     "$old_name__new_name__pairs" |
	while read old_name  new_name
	   do	[[ $old_name && $new_name ]] || continue
		[[ -e $old_name ]] || continue
		run_cmd mv $old_name $new_name
	done
	local file
	for file in .snap/*.sha1
	    do	[[ -s $file ]] || continue
		run_cmd sed -i \
		   's@.snap.local$@files-local@; s@.snap$@files-repo@' $file
	done
	return 0
}

# ----------------------------------------------------------------------------

source_config() {
	local file=$1

	[[ -s  $file ]] || return 1
	source $file || error "$file ended with non-0 status"
}

# ----------------------------------------------------------------------------

compute_metadata() {

	expand > $_tmp <<-\EOF
	import sys, os, os.path, time
	from os.path import getsize, getmtime

	def timestr(secs):
	    return time.strftime( '%Y-%m-%d %H:%M:%S UTC', time.gmtime(secs) )

	for path in sys.stdin:
	    path = path.rstrip()
	    if os.path.islink(path):
	        print("{} -> {}".format(path, os.readlink(path)))
	    else:
	        # snap's files_to_paths assumes 2 spaces after filename
	        print("{}  {:,}B  {}".format(path,   getsize (path),
					     timestr(getmtime(path))))
	EOF

	python $_tmp
	rm $_tmp
}

# -------------------------------------------------------

write_metadata() {

	if [[ $our_name == snapserv ]]
	   then local metadata_file=.snap/files-repo
	   else local metadata_file=.snap/files-local
	fi
	run_cmd mkdir -p .snap	  # might be fixing a half-initialized project

	[[ ${Run-} ]] && metadata_file=/dev/tty
	local dir fgrep_opts=
	for dir in $snappable_subdirs
	    do	fgrep_opts="$fgrep_opts -e $dir"
	done
	# the emacs temps in the -name patterns are duplicated in rsync_opts
	find * \( -type f -o -type l \) \
	     ! -name '*~' ! -name '#*#' ! -name '.#*' | # ignore emacs temps
	  fgrep $fgrep_opts | sort | compute_metadata > $metadata_file

	if have_cmd shasum
	   then local sha_cmd=shasum
	   else local sha_cmd=sha1sum
	fi
	if [[ ! ${Run-} ]]
	   then cd_ .snap
		metadata_file=${metadata_file#.snap/}
		$sha_cmd $metadata_file > $metadata_file.sha1
		cd_ ..
	fi
}
