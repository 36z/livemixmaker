#!/bin/bash

shopt -s expand_aliases
#[ ! $PS1 ] && set -e  # exit on error in non-interactive terminals

progname=$(basename $0)
function print { echo ${progname}: $@ 1>&2; }  # TODO: have this replace echo

# define pushd/popd if this is not bash? is this even to consider since pretty much everything else relies on bash
! type pushd >/dev/null &&
alias pushd='DIRS="$PWD
$DIRS"; cd' # mind the newline!
! type popd >/dev/null &&
alias popd='oldpwd=$(echo "$DIRS" | sed -ne '1p'); [ $oldpwd ] && cd $oldpwd; DIRS=$(echo "$DIRS" | sed -e '1d')'

alias mkdir="mkdir --parents"
alias mount="mount --verbose"
alias umount="umount -f"
alias cp="cp --recursive"
alias grep="grep --perl-regexp"
alias config_diff="diff --recursive --new-file --ignore-all-space --ignore-blank-lines --minimal"
alias skip_comments="grep -v '^\s*(#|$)'"

function extract() {
  case "$*" in
    *.tar.gz)   tar xvzf --overwrite "$@" ;;
    *.tar.bz2)  tar xjvf --overwrite "$@" ;;
    *.zip)      unzip -o "$@" ;;
    *) echo "extract: '$@' unknown compression type" && return 1 ;;
  esac
}

function test_admin {
  if [ $UID -gt 500 ]; then
    echo 'ERROR: Cetain actions, like this one, must be run as privileged user. This user is one of them.'
    exit 12
  fi
}

function to_bytes { eval ${1}=$(units -t -o %.0f $(echo ${!1} | sed -r 's/b/B/g' | sed -r 's/(.*[^B])$/\1B/') B); }
function to_MB { eval ${1}=$(units -t -o %.0f $(echo ${!1}) MB); }

function looks_like_url { if echo $1 | grep '^(https?|ftp)://'; then return 0; fi; return 1; }
function strip_url_scheme { echo "$1" | sed -r 's,^(https?|ftp)://,,'; }
function is_script_file { file "$1" | grep 'script' >/dev/null; }

function chroot_exec {
  chroot ${CHROOT} /bin/bash -c "$1"
  if [ "$?" != "0" ] && [ ! $IGNORE_ERRORS ]; then
    echo '----- Error encountered: see above.'
    exit 14
  fi
}
function chroot_aptget { chroot_exec "apt-get -y -o Acquire::http::Proxy="$MIRROR_PROXY" -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $APT_OPTIONS $1"; }
function backup_chroot { tar -C "$CHROOT" -cf- . | gzip --fast --stdout > "$1" || rm "$1"; }
function restore_chroot { gzip --decompress --stdout "$1" | tar -x -f- -C "$CHROOT"; }

# TODO: try if everything works without mounting /sys
function mount_devices  { for fs in dev dev/pts proc sys; do mount -o bind "/${fs}/" "${CHROOT}/${fs}"; done }  # bind local dev,proc,sys into chroot
function umount_devices { for fs in dev/pts dev proc sys; do umount -f ${CHROOT}/${fs} 2>/dev/null || true; done }
function get_mounted_device { echo $(losetup --all | grep "($BUILD/binary.img)" | cut -d: -f1); }

function losetup_attach {
  local mounted_device="$(get_mounted_device)"
  if [ $mounted_device ]; then
    DEVICE="$mounted_device"
  else
    DEVICE=$(losetup --find --show binary.img);
  fi
}
function losetup_detach { sync; sleep 1; losetup --detach "$(get_mounted_device)"; sleep 1; }

function mount_filesystems {
  if mount | grep " $CHROOT " >/dev/null; then
    echo "Already mounted $CHROOT"
  else
    echo 'Mounting filesystems ...'
    mkdir "${CHROOT}" 2>/dev/null || true
    mount -t ext4 "${DEVICE}p2" "$CHROOT"
    for dir in "home" "mnt/ntfs" "dev" "proc" "sys"; do
      mkdir "$CHROOT/$dir" 2>/dev/null || true
    done
    [ $separate_home ] &&
      mount -t ext4 "${DEVICE}p3" "$CHROOT/home"
    mount -t ntfs-3g "${DEVICE}p1" "$CHROOT/mnt/ntfs"
  fi
  # ensure we report chrooted environment, otherwise the host system may go funny after certain installs
  create_policyrc_d_101
  set_ischroot_true
  set_resolv_conf
}

function umount_filesystems {
  # make sure you umount here just anything ever bind-mounted! otherwise detaching a busy loop device fails!
  destroy_policyrc_d_101
  reset_ischroot
  reset_resolv_conf
  umount "$CHROOT/_local_packages/" 2>/dev/null || true
  umount "$CHROOT/_livemixmaker/" 2>/dev/null || true
  sync; sleep 1; sync
  umount "${CHROOT}/mnt/ntfs" 2>/dev/null || true
  [ $separate_home ] &&
    umount "${CHROOT}/home" 2>/dev/null || true
  umount_devices
  umount "${CHROOT}" 2>/dev/null || true
}

function zero_partitions {
  for partition in "${CHROOT}" "${CHROOT}/home" "${CHROOT}/mnt/ntfs"; do
    # TODO: consider zerofree, virt-sparsify
    echo "Zeroing partition ${partition}"
    cat /dev/zero > "${partition}/_empty_space" || true
    sync; sleep 1; sync;
    rm "${partition}/_empty_space"
  done
}

function cleanup {
  sync; sleep 1; sync
  echo 'Exit. Cleaning up ...'
  umount_filesystems
  sync; sleep 1
  losetup_detach
  exit 111
}

function clean_build {
  rm -rf parent config binary.img base.stage || true
  rmdir chroot || true
  mkdir chroot cache || true
}

function print_usage {
  cat <<END
usage: livemixmaker { init | build | gzip | clean | cleanall |
                    [u]mount | vbox }

Create live-USB, persistent Debian-based remixes.

All commands with exception of 'init' must be run in a directory where
a 'config' directory is present. Run \`livemixmaker init\` for more info.

init      Copies distribution example config template into \$PWD.
build     Starts the build process. Here's the candy.
gzip      Gzips build/binary.img into a compressed redistributable.
clean     Removes build/binary.img so that 'build' command starts anew.
          Note that build/cache directory (with backed-up bootstrap and
          parent base) is left intact.
cleanall  Removes the build directory altogether. Also resets any
          confighook scripts and removes their provided files. See
          example config/README for more information.
mount     Mounts build/binary.img onto build/chroot/ for manual tinkering.
umount    Graceful reverse. DO USE THIS. ;)
vbox      Uses qemu-img, if available, to convert raw build/binary.img
          into a VirtualBox-compatible VMDK image in \$PWD.

Program arguments with defaults (POSIX style, passed *BEFORE* the
program name):
$(cat $(which $0) | sed -n '/^#startprogargs/,/^#endprogargs/p' | sed 's/^/  /')

Example:
 $ livemixmaker init
 $ ARCH=amd64 SUITE=sid  livemixmaker build

All above arguments can also be provided in config/build.conf, which is
sourced, and these including any other arguments you pass in this way are
exported, so they can be referred to in your hook scripts.
END
}

# these functions provide usable chroot
function set_ischroot_true { mount --bind "$CHROOT/bin/true" "$CHROOT/usr/bin/ischroot" 2>/dev/null || true; }
function reset_ischroot { umount "$CHROOT/usr/bin/ischroot" 2>/dev/null || true; }
function set_resolv_conf { mount --bind /etc/resolv.conf "$CHROOT/etc" 2>/dev/null || true; }
function reset_resolv_conf { umount "$CHROOT/etc/resolv.conf" 2>/dev/null || true; }
function destroy_policyrc_d_101 { rm "$CHROOT/usr/sbin/policy-rc.d" || true; }
function create_policyrc_d_101 {
  mkdir "$CHROOT/usr/sbin/"
  echo -e "#!/bin/sh \n exit 101" > "$CHROOT/usr/sbin/policy-rc.d"
  chmod a+x "$CHROOT/usr/sbin/policy-rc.d"
}

function process_config_confighooks {
  pushd "$1" >/dev/null
    echo "----- Processing $(basename $PWD) ..."
    while read hook ; do
      # execute only permissible script-files
      if [ -x $hook ]; then
        echo "$hook:"
        ./"$hook" && chmod -x "$hook"  # on successful run, mark scripts unexecutable
        if [ "$?" != "0" ]; then
          echo "Error: Confighook $(basename $PWD)/$hook errored, and it can't be overriden with IGNORE_ERRORS"
          exit 78
        fi
      fi
    done < <(ls)
  popd >/dev/null
}

function process_config_parents {
  pushd "$1" >/dev/null
  unset PARENT && . ./build.conf
  local parents="$PARENT"
  if [ ! -z "$parents" ]; then
    echo '----- Processing parents ...'
    while read line; do
      # parent specified as path
      if cd "$line/config" && local parent_config="$(pwd)" && cd - ; then
        echo "Found parent: $line"
        process_config "$parent_config"
        
      # parent specified as URL address of archive  
      elif looks_like_url "$line"; then
        # don't re-download if archive in cache
        cache_name=$(echo "$line" | tr --complement '[:alnum:]\n' '.')
        mkdir "$BUILD/cache/parent" || true
        if [ ! -f "$BUILD/cache/$cache_name" ]; then
          wget --output-document="$BUILD/cache/$cache_name" "$line"
        fi
        pushd "$BUILD/cache" >/dev/null
          extract "$cache_name"
          touch -t 197101231337 "$cache_name"  # FIXME: because we don't know the extracted directory name, when sorted by time, make sure archives all at the back
          local parent_name=$(ls -t | head -1)
          mv "$parent_name" "$BUILD/parent/"
        popd >/dev/null
        echo "Found parent: $parent_name"
        process_config "$(find "$BUILD/parent/$parent_name" -type d -name 'config' -print | head -1)"

      # parent as a result of command line execution
      elif [ $line ]; then
        echo 'parent as command-line: TBD.' # TODO
        exit 8
      fi
    done < <(echo "$parents")
  fi
  popd >/dev/null
}

function process_config_chroot {
  pushd "$1" >/dev/null
    echo "----- Copying chroot $(basename $PWD)..."
    cp --force --verbose "./." "${CHROOT}/"
  popd >/dev/null
}

function process_config_packagelists {
  pushd "$1" >/dev/null
    echo "----- Installing packages from $(basename $PWD)..."
    # select all non-commented package lines, strip spaces
    package_list="$(grep -Rho '^[^#]+' *.list | sed -r 's/(^\s+|\s+$)//')"
    # first pass only replace any commands for their resulting outputs
    while read line; do
      # if line starts with a !, then it is a command, which should return \n-separated list of packages
      if [ "${line::1}" = "!" ]; then
        insert_packages="$(exec ${line:1})"
        package_list="${package_list/"${line}"/$insert_packages}"
      fi
    done < <(echo "$package_list")
    # second pass, select packages
    unset install_pkgs remove_pkgs remove_pkgs_install_line
    while read package; do
      # TODO: provide more robust layer around packages in (regex) format:
      #   [+-]?package_name(/target_release)?
      if [ "${package::1}" = '-' ]; then
        remove_pkgs="$remove_pkgs ${package:1}"
        remove_pkgs_install_line="$remove_pkgs_install_line ${package:1}-"
      else
        install_pkgs="$install_pkgs ${package}"
      fi
    done < <(echo "$package_list" | tr ' ' '\n')
    # install; if installation via single line fails, try first install then remove
    echo "Install: $install_pkgs"
    echo "Remove or hold: $remove_pkgs"
    if ! chroot_aptget "install $install_pkgs $remove_pkgs_install_line"; then
      chroot_aptget "install $install_pkgs"
      chroot_aptget "purge $remove_pkgs"
    fi
  popd >/dev/null
}

function process_config_localpackages {
  pushd "$1" >/dev/null
    if [ $(ls | wc -l) = "0" ]; then
      echo "WARNING: skipping ZERO packages in $(basename $PWD)"
    else
      echo "----- Installing packages from $(basename $PWD) ..."
      # TODO: if gdebi exists, use gdebi
      apt-ftparchive packages . >> Packages
      apt-ftparchive release . >> Release
      mkdir "${CHROOT}/_local_packages" || true
      mount -o bind . "${CHROOT}/_local_packages/"  # "copy" packages inside chroot
      echo "deb file:///_local_packages ./" > "${CHROOT}/etc/apt/sources.list.d/_local_packages.list"
      # update with the new 'archive' and install provided packages
      install_pkgs="$(grep '^Package: ' Packages | cut -d' ' -f2 | tr '\n' ' ')"
      echo "Install: $install_pkgs"
      chroot_aptget "update"
      chroot_aptget "--allow-unauthenticated install $install_pkgs"  # TODO: self-sign the packages as live-build does
      # clean-up
      rm Packages Release
      umount -f "${CHROOT}/_local_packages"
      rm "${CHROOT}/etc/apt/sources.list.d/_local_packages.list"
      rmdir "$CHROOT/_local_packages"
    fi
  popd >/dev/null
}

function process_config_hooks {
  # bind-mount ./config directory as $CHROOT_CONFIG so hooks can pull in additional resources if necessary
  mkdir "$CHROOT/$CHROOT_CONFIG"
  mount --bind "$(dirname $1)" "$CHROOT/$CHROOT_CONFIG"
  pushd "$CHROOT/$CHROOT_CONFIG/$(basename $1)/" >/dev/null
    hooks_dir=$(basename $PWD)
    echo "----- Processing chroot hooks in $hooks_dir..."
    # prepare folder in chroot
    for hook in $(ls); do
      # execute only permissible script-files
      if is_script_file "$hook"; then
        if [ -x "$hook" ]; then
          echo "$hook:"
          chroot_exec "/$CHROOT_CONFIG/$hooks_dir/$hook"
        else
          echo "---- WARNING: Un-executable script file: $hooks_dir/$hook"
        fi
      fi
    done
  popd >/dev/null
  umount -f "$CHROOT/$CHROOT_CONFIG" || true
  rmdir "$CHROOT/$CHROOT_CONFIG" || true
}

function get_processing_function { # $1 = config/n.THIS_DIRNAME
  # attempt at an associative array; maps dirname to funcname
  declare -A fmap
  fmap[confighooks]=confighooks
  fmap[chroot]=chroot
  fmap[package-lists]=packagelists
  fmap[packages]=localpackages
  fmap[hooks]=hooks
  func_name="${fmap[$1]}"
  [ $func_name ] && echo "process_config_${func_name}" ||
                    echo ''
}

function process_config {
  local confdir="$1"
  for dir in $(ls --directory $confdir/0.* 2>/dev/null); do
    dir="$(basename $dir)"
    process_func="$(get_processing_function ${dir:2})"
    [ $process_func ] && eval $process_func "$confdir/$dir" ||
      echo "warning: skipping unidentified dir $dir"
  done
  
  process_config_parents   "$confdir"
  
  for dir in $(ls --directory $confdir/[1-9]*.* 2>/dev/null); do
    dir="$(basename $dir)"
    process_func="$(get_processing_function ${dir#[1-9]*.})"
    [ $process_func ] && eval $process_func "$confdir/$dir" ||
      echo "warning: skipping unidentified dir $dir"
  done
}

