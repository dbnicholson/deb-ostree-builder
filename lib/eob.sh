#!/bin/bash
# -*- mode: Shell-script; sh-basic-offset: 2; indent-tabs-mode: nil -*-
shopt -s nullglob
shopt -s extglob

# Show current script and time when xtrace (set -x) enabled. Will look
# like "+ 10:13:40 run-build: some command".
export PS4='+ \t ${BASH_SOURCE[0]##*/}: '

# Run hooks under customization/
run_hooks() {
  local hook interpreter
  local group=$1
  local install_root=$2

  echo "Running $group hooks"

  # Sort enabled hooks
  eval local hooks="\${EOB_${group^^}_HOOKS}"
  local files=$(echo "${hooks}" | tr ' ' '\n' | sort)

  for hook in ${files}; do
    local hookpath="${EOB_SRCDIR}"/hooks/${group}/${hook}
    if [ ! -f "${hookpath}" ]; then
      echo "Missing hook ${hookpath}!" >&2
      return 1
    fi

    if [ "${hook: -7}" == ".chroot" ]; then
      if [ -z "$install_root" ]; then
        echo "Skipping hook, no chroot available: ${hook}"
        continue
      fi

      echo "Run hook in chroot: ${hook}"
      [ -x "${hook}" ] && interpreter= || interpreter="bash -ex"
      mkdir -p $install_root/tmp
      cp ${hookpath} $install_root/tmp/hook
      chroot $install_root $interpreter /tmp/hook
      rm -f $install_root/tmp/hook
      continue
    fi

    echo "Run hook: ${hook}"
    if [ -x "${hookpath}" ]; then
      ${hookpath}
    else
      (
        . ${hookpath}
      )
    fi
  done
}

# Install packages with apt
pkg_install() {
  chroot "${EOB_ROOTDIR}" apt-get --yes \
    -o Debug::pkgProblemResolver=true install "$@"
}

# Declare the EOB_MOUNTS array, but don't reinitialize it.
declare -a EOB_MOUNTS

# Mount a filesystem and track the target mount point.
eob_mount() {
  local target

  if [ $# -lt 2 ]; then
    echo "At least 2 arguments needed to $FUNCNAME" >&2
    return 1
  fi

  mount "$@"

  # The target is the last argument
  eval target="\${$#}"
  EOB_MOUNTS+=("${target}")
}

# Unmount all tracked mount points.
eob_umount_all() {
  local -i n

  # Work from the end of the array to unmount submounts first
  for ((n = ${#EOB_MOUNTS[@]} - 1; n >= 0; n--)); do
    umount "${EOB_MOUNTS[n]}"
  done

  # Clear and re-declare the array
  unset EOB_MOUNTS
  declare -a EOB_MOUNTS
}

# Provide the path to the keyring file. If it doesn't exist, create it.
eob_keyring() {
  local keyring="${EOB_TMPDIR}"/eob-keyring.gpg
  local keysdir="${EOB_DATADIR}"/keys
  local -a keys
  local keyshome key

  # Create the keyring if necessary
  if [ ! -f "${keyring}" ]; then
    # Check that there are keys
    if [ ! -d "${keysdir}" ]; then
      echo "No gpg keys directory at ${keysdir}" >&2
      return 1
    fi
    keys=("${keysdir}"/*.asc)
    if [ ${#keys[@]} -eq 0 ]; then
      echo "No gpg keys in ${keysdir}" >&2
      return 1
    fi

    # Create a homedir with proper 0700 perms so gpg doesn't complain
    keyshome=$(mktemp -d --tmpdir="${EOB_TMPDIR}" eob-keyring.XXXXXXXXXX)

    # Import the keys
    for key in "${keys[@]}"; do
      gpg --batch --quiet --homedir "${keyshome}" --keyring "${keyring}" \
        --no-default-keyring --import "${key}"
    done

    # Set normal permissions for the keyring since gpg creates it 0600
    chmod 0644 "${keyring}"

    rm -rf "${keyshome}"
  fi

  echo "${keyring}"
}

# Try to work around a race where partx sometimes reports EBUSY failure
eob_partx_scan() {
  udevadm settle
  local i=0
  while ! partx -a -v "$1"; do
	(( ++i ))
	[ $i -ge 10 ] && break
    echo "partx scan $1 failed, retrying..."
    sleep 1
  done
}

# Work around a race where loop deletion sometimes fails with EBUSY
eob_delete_loop() {
  udevadm settle
  local i=0
  while ! losetup -d "$1"; do
	(( ++i ))
	[ $i -ge 10 ] && break
    echo "losetup remove $1 failed, retrying..."
    sleep 1
  done
}

recreate_dir() {
  rm -rf $1
  mkdir -p $1
}

# Make a minimal chroot with the EOS ostree to use during the build.
make_tmp_ostree() {
  local packages=ostree
  local keyring

  # Include the keyring package to verify pulled commits.
  # XXX what's the keyring for ostree commits on debian?
  packages+=",debian-archive-keyring"

  # Include ca-certificates to silence nagging from libsoup even though
  # we don't currently use https for ostree serving.
  packages+=",ca-certificates"

  # FIXME: Shouldn't need to specify pinentry-curses here, but
  # debootstrap can't deal with the optional dependency on
  # pinentry-gtk2 | pinentry-curses | pinentry correctly.
  packages+=",pinentry-curses"

  recreate_dir "${EOB_OSTREE_TMPDIR}"
  keyring=$(eob_keyring)
  debootstrap --arch=${EOB_ARCH} --keyring="${keyring}" \
    --variant=minbase --include="${packages}" \
    --components="${EOB_OS_COMPONENTS}" ${EOB_BRANCH} \
    "${EOB_OSTREE_TMPDIR}" "${EOB_OS_REPO}" \
    "${EOB_DATADIR}"/debootstrap.script
}

# Common cleanup actions for the ostree chroot.
cleanup_tmp_ostree() {
  # Kill the running gpg-agent launched when signing the ostree commit.
  # SIGINT is used to make the agent shutdown immediately.
  #
  # XXX: This would break concurrent builds. If that ever happens, the
  # running agent's pid can be found like so:
  #
  # chroot "${EOB_OSTREE_TMPDIR}" \
  #   gpg-connect-agent --homedir "${EOB_SYSCONFDIR}/gnupg" \
  #   --no-autostart "getinfo pid" /bye
  pkill -INT -f "gpg-agent.*${EOB_SYSCONFDIR}/gnupg" || :
}

# Run the temporary ostree within the chroot.
tmp_ostree() {
  chroot "${EOB_OSTREE_TMPDIR}" ostree "$@"
}

# Emulate the old ostree write-refs builtin where a local ref is forced
# to the commit of another ref.
tmp_ostree_write_refs() {
  local repo=${1:?No ostree repo supplied to ${FUNCNAME}}
  local src=${2:?No ostree source ref supplied to ${FUNCNAME}}
  local dest=${3:?No ostree dest ref supplied to ${FUNCNAME}}
  local destdir=${dest%/*}

  # Create the needed directory for the dest ref.
  chroot "${EOB_OSTREE_TMPDIR}" mkdir -p "${repo}/refs/heads/${destdir}"

  # Copy the source ref file to the dest ref.
  chroot "${EOB_OSTREE_TMPDIR}" cp -f "${repo}/refs/heads/${src}" \
    "${repo}/refs/heads/${dest}"
}

true
