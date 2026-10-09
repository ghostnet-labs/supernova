#!/usr/bin/env zsh
# Files and disks: space, mounts, compress, extract, fvfind, and fbfind.
# .zshrc sources every file in dotfiles/functions/.

_space_help() {
  cat <<'EOF'
Usage:
  space [PATH]
  space files [PATH]
  space browse [PATH]
  space vm
  space -h | --help

Description:
  Report allocated disk usage without crossing filesystem boundaries. The
  default view shows PATH's filesystem and its immediate children. PATH
  defaults to the current directory; unreadable entries are omitted.

Options:
  files [PATH]   Show the 50 largest individual files below PATH.
  browse [PATH]  Browse usage with ncdu in read-only mode.
  vm             Show the root filesystem and its immediate children.
  -h, --help     Show this help menu.

Examples:
  space
  space /tmp
  space files ~/dev
  space browse /
  space vm
EOF
}

_space_utilization() {
  local target="$1"

  print
  command df -h "$target" || return $?
  print
}

_space_summary() {
  local target="$1"

  _space_utilization "$target" || return $?
  print -r -- "Allocated disk usage (immediate children): $target"

  # BSD du rejects -a with -d, so size each child on the target's filesystem.
  local device
  local -a children
  zmodload -F zsh/stat b:zstat 2>/dev/null
  device="$(zstat -L +device -- "$target")" || return $?
  children=("$target"/*(DNe:'[[ "$(zstat -L +device -- "$REPLY" 2>/dev/null)" == "$device" ]]':))
  {
    command du -shx -- "$target" 2>/dev/null
    (( $#children )) && command du -shx -- "${children[@]}" 2>/dev/null
  } | command sort -hr
}

_space_files() {
  local target="$1"

  _space_utilization "$target" || return $?
  print -r -- "Largest individual files (allocated; top 50): $target"
  command find "$target" -xdev -type f -exec du -h {} + 2>/dev/null |
    command sort -hr |
    command sed -n '1,50p'
}

# toolbox: filesystem | Inspect filesystem utilization and disk consumption.
# toolbox-args: [PATH] | files [PATH] | browse [PATH] | vm
# toolbox-example: space
# toolbox-example: space files ~/dev
# toolbox-example: space browse /
# toolbox-example: space vm
space() {
  emulate -L zsh

  local mode="summary"
  local target="$PWD"

  case "${1:-}" in
    -h|--help)
      _space_help
      return 0
      ;;
    files|browse)
      mode="$1"
      shift
      (( $# <= 1 )) || {
        print -u2 -r -- "space: $mode accepts at most one path"
        print -u2 -r -- "Run 'space --help' for usage."
        return 2
      }
      target="${1:-$PWD}"
      ;;
    vm)
      shift
      (( $# == 0 )) || {
        print -u2 -r -- "space: vm does not accept a path"
        print -u2 -r -- "Run 'space --help' for usage."
        return 2
      }
      target="/"
      ;;
    -*)
      print -u2 -r -- "space: unknown option: $1"
      print -u2 -r -- "Run 'space --help' for usage."
      return 2
      ;;
    *)
      (( $# <= 1 )) || {
        print -u2 -r -- "space: expected at most one path"
        print -u2 -r -- "Run 'space --help' for usage."
        return 2
      }
      target="${1:-$PWD}"
      ;;
  esac

  [[ -d "$target" ]] || {
    print -u2 -r -- "space: not a directory: $target"
    return 2
  }
  target="${target:A}"

  case "$mode" in
    files)
      _space_files "$target"
      ;;
    browse)
      command -v ncdu >/dev/null 2>&1 || {
        print -u2 -r -- "space: ncdu is required for browse mode"
        return 127
      }
      command ncdu -x -rr "$target"
      ;;
    *)
      _space_summary "$target"
      ;;
  esac
}

_mounts_help() {
  cat <<'EOF'
Usage:
  mounts
  mounts -h | --help

Description:
  Show capacity and utilization for mounted filesystems. Physical, network, and
  user filesystems are retained; temporary, kernel, and container-layer
  filesystems are omitted.

Options:
  -h, --help    Show this help menu.

Examples:
  mounts
EOF
}

# toolbox: filesystem system | Show mounted filesystem capacity and utilization.
# toolbox-example: mounts
mounts() {
  emulate -L zsh

  case "${1:-}" in
    -h|--help)
      _mounts_help
      return 0
      ;;
  esac
  (( $# == 0 )) || {
    print -u2 -r -- "mounts: this command does not accept arguments"
    print -u2 -r -- "Run 'mounts --help' for usage."
    return 2
  }

  local df_output has_type=false
  if [[ "$OSTYPE" == linux* ]]; then
    local -a excluded_types
    excluded_types=(
      tmpfs devtmpfs squashfs overlay efivarfs proc sysfs cgroup cgroup2
      debugfs tracefs pstore securityfs configfs fusectl autofs ramfs
    )
    local -a exclusion_args
    local filesystem_type
    for filesystem_type in "${excluded_types[@]}"; do
      exclusion_args+=(-x "$filesystem_type")
    done
    df_output="$(command df -hPT "${exclusion_args[@]}" 2>/dev/null)" || {
      print -u2 -r -- "mounts: could not read filesystem utilization"
      return 1
    }
    has_type=true
  else
    df_output="$(command df -hP 2>/dev/null)" || {
      print -u2 -r -- "mounts: could not read filesystem utilization"
      return 1
    }
  fi

  command awk -v has_type="$has_type" '
    BEGIN {
      device_width = 6
      type_width = 4
      size_width = 4
      used_width = 4
      avail_width = 5
      use_width = 3
    }
    NR == 1 { next }
    {
      device = $1
      if (has_type == "true") {
        type = $2
        size = $3
        used = $4
        avail = $5
        use = $6
        mount_start = 7
      } else {
        type = "-"
        size = $2
        used = $3
        avail = $4
        use = $5
        mount_start = 6
        if (device == "devfs" || device == "map") {
          next
        }
      }

      mount = $mount_start
      for (field_index = mount_start + 1; field_index <= NF; field_index++) {
        mount = mount " " $field_index
      }
      row_count++
      devices[row_count] = device
      types[row_count] = type
      sizes[row_count] = size
      used_values[row_count] = used
      available[row_count] = avail
      uses[row_count] = use
      mounts[row_count] = mount
      if (length(device) > device_width) device_width = length(device)
      if (length(type) > type_width) type_width = length(type)
      if (length(size) > size_width) size_width = length(size)
      if (length(used) > used_width) used_width = length(used)
      if (length(avail) > avail_width) avail_width = length(avail)
      if (length(use) > use_width) use_width = length(use)
    }
    END {
      if (row_count == 0) {
        print "No mounted filesystems found."
        exit
      }
      printf "%-*s %-*s %*s %*s %*s %*s %s\n", device_width, "DEVICE",
        type_width, "TYPE", size_width, "SIZE", used_width, "USED",
        avail_width, "AVAIL", use_width, "USE", "MOUNT"
      for (row_index = 1; row_index <= row_count; row_index++) {
        printf "%-*s %-*s %*s %*s %*s %*s %s\n", device_width,
          devices[row_index], type_width, types[row_index], size_width,
          sizes[row_index], used_width, used_values[row_index], avail_width,
          available[row_index], use_width, uses[row_index], mounts[row_index]
      }
    }
  ' <<<"$df_output"
}

_compress_help() {
  cat <<'EOF'
Usage:
  compress [--force] SOURCE [ARCHIVE]
  compress -h | --help

Description:
  Compress one file or directory. Without ARCHIVE, directories become adjacent
  .tar.gz archives and files become adjacent .gz files. An explicit extension
  selects tar, tar.gz, tgz, tar.bz2, tar.xz, tar.zst, zip, 7z, gz, bz2, xz, or
  zst. Single-stream formats accept files only. Partial archives are cleaned up.

Options:
  --force       Replace an existing archive after compression succeeds.
  -h, --help    Show this help menu.

Examples:
  compress diagnostics
  compress server.log
  compress release release.tar.zst
  compress --force results results.zip
EOF
}

_compress_cleanup() {
  local temp_archive="$1"
  local temp_dir="$2"

  [[ -n "$temp_archive" ]] && command rm -f -- "$temp_archive"
  [[ -n "$temp_dir" ]] && command rmdir -- "$temp_dir" 2>/dev/null
}

# toolbox: filesystem archive | Create compressed files and archives safely.
# toolbox-args: [--force] SOURCE [ARCHIVE]
# toolbox-example: compress diagnostics
# toolbox-example: compress server.log
# toolbox-example: compress release release.tar.zst
compress() {
  emulate -L zsh
  setopt local_options local_traps pipe_fail

  local force=false
  local -a positional
  while (( $# )); do
    case "$1" in
      -h|--help)
        _compress_help
        return 0
        ;;
      --force)
        force=true
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -*)
        print -u2 -r -- "compress: unknown option: $1"
        print -u2 -r -- "Run 'compress --help' for usage."
        return 2
        ;;
      *)
        positional+=("$1")
        ;;
    esac
    shift
  done

  if (( ${#positional} < 1 || ${#positional} > 2 )); then
    print -u2 -r -- "compress: a source and optional archive are required"
    print -u2 -r -- "Run 'compress --help' for usage."
    return 2
  fi

  local source="${~positional[1]}"
  source="${source:A}"
  [[ -f "$source" || -d "$source" ]] || {
    print -u2 -r -- "compress: source not found: $source"
    return 1
  }
  [[ -r "$source" ]] || {
    print -u2 -r -- "compress: source is not readable: $source"
    return 1
  }

  local archive
  if (( ${#positional} == 2 )); then
    archive="${~positional[2]}"
  elif [[ -d "$source" ]]; then
    archive="${source:h}/${source:t}.tar.gz"
  else
    archive="${source}.gz"
  fi
  archive="${archive:A}"

  [[ "$archive" != "$source" ]] || {
    print -u2 -r -- "compress: archive must differ from source"
    return 2
  }
  if [[ -d "$source" && "$archive" == "$source"/* ]]; then
    print -u2 -r -- "compress: archive cannot be created inside its source directory"
    return 2
  fi
  [[ -d "${archive:h}" ]] || {
    print -u2 -r -- "compress: archive directory not found: ${archive:h}"
    return 1
  }
  if [[ ( -e "$archive" || -L "$archive" ) && "$force" != true ]]; then
    print -u2 -r -- "compress: archive already exists: $archive"
    print -u2 -r -- "Use --force to replace it."
    return 1
  fi

  local archive_name="${archive:t}"
  local lower_name="${archive_name:l}"
  local format="" stream_format=false
  local -a required_tools
  case "$lower_name" in
    *.tar.gz|*.tgz)
      format="tar-gz"
      required_tools=(tar gzip)
      ;;
    *.tar.bz2)
      format="tar-bz2"
      required_tools=(tar bzip2)
      ;;
    *.tar.xz)
      format="tar-xz"
      required_tools=(tar xz)
      ;;
    *.tar.zst)
      format="tar-zst"
      required_tools=(tar zstd)
      ;;
    *.tar)
      format="tar"
      required_tools=(tar)
      ;;
    *.zip)
      format="zip"
      required_tools=(zip)
      ;;
    *.7z)
      format="7z"
      required_tools=(7z)
      ;;
    *.gz)
      format="gz"
      stream_format=true
      required_tools=(gzip)
      ;;
    *.bz2)
      format="bz2"
      stream_format=true
      required_tools=(bzip2)
      ;;
    *.xz)
      format="xz"
      stream_format=true
      required_tools=(xz)
      ;;
    *.zst)
      format="zst"
      stream_format=true
      required_tools=(zstd)
      ;;
    *)
      print -u2 -r -- "compress: unsupported archive format: $archive_name"
      return 2
      ;;
  esac

  if [[ "$stream_format" == true && ! -f "$source" ]]; then
    print -u2 -r -- "compress: .$format accepts files only; use a tar archive for directories"
    return 2
  fi

  local tool
  for tool in "${required_tools[@]}"; do
    if (( ! $+commands[$tool] )); then
      print -u2 -r -- "compress: $tool is required for $archive_name"
      return 1
    fi
  done

  local -i file_count=1 source_bytes=0 archive_bytes=0 start_seconds=$SECONDS
  if [[ -d "$source" ]]; then
    file_count="$(command find "$source" -type f -print0 2>/dev/null | command tr -cd '\0' | command wc -c)"
    source_bytes="$(( $(command du -sk "$source" 2>/dev/null | command awk 'NR == 1 { print $1 }') * 1024 ))"
  else
    source_bytes="$(command wc -c <"$source")"
  fi

  local temp_dir temp_archive
  temp_dir="$(command mktemp -d "${archive:h}/.compress.XXXXXX")" || {
    print -u2 -r -- "compress: could not create temporary output in ${archive:h}"
    return 1
  }
  temp_archive="$temp_dir/$archive_name"
  trap '[[ -n "$temp_archive" ]] && command rm -f -- "$temp_archive"; [[ -n "$temp_dir" ]] && command rmdir -- "$temp_dir" 2>/dev/null' EXIT INT TERM HUP

  local -i compression_status=0
  case "$format" in
    tar)
      command tar -cf "$temp_archive" -C "${source:h}" "${source:t}" || compression_status=$?
      ;;
    tar-gz)
      command tar -czf "$temp_archive" -C "${source:h}" "${source:t}" || compression_status=$?
      ;;
    tar-bz2)
      command tar -cjf "$temp_archive" -C "${source:h}" "${source:t}" || compression_status=$?
      ;;
    tar-xz)
      command tar -cJf "$temp_archive" -C "${source:h}" "${source:t}" || compression_status=$?
      ;;
    tar-zst)
      command tar -cf - -C "${source:h}" "${source:t}" |
        command zstd -q -c >"$temp_archive" || compression_status=$?
      ;;
    zip)
      (builtin cd -- "${source:h}" && command zip -qr "$temp_archive" "${source:t}") || compression_status=$?
      ;;
    7z)
      (builtin cd -- "${source:h}" && command 7z a -bd -y "$temp_archive" "${source:t}" >/dev/null) || compression_status=$?
      ;;
    gz)
      command gzip -c -- "$source" >"$temp_archive" || compression_status=$?
      ;;
    bz2)
      command bzip2 -c -- "$source" >"$temp_archive" || compression_status=$?
      ;;
    xz)
      command xz -c -- "$source" >"$temp_archive" || compression_status=$?
      ;;
    zst)
      command zstd -q -c -- "$source" >"$temp_archive" || compression_status=$?
      ;;
  esac

  if (( compression_status )); then
    _compress_cleanup "$temp_archive" "$temp_dir"
    temp_archive=""
    temp_dir=""
    trap - EXIT INT TERM HUP
    print -u2 -r -- "compress: compression failed: $source"
    return "$compression_status"
  fi

  if [[ "$force" == true ]]; then
    command mv -f -- "$temp_archive" "$archive"
    local -i move_status=$?
    if (( move_status )); then
      _compress_cleanup "$temp_archive" "$temp_dir"
      temp_archive=""
      temp_dir=""
      trap - EXIT INT TERM HUP
      return "$move_status"
    fi
  else
    if [[ -e "$archive" || -L "$archive" ]]; then
      _compress_cleanup "$temp_archive" "$temp_dir"
      temp_archive=""
      temp_dir=""
      trap - EXIT INT TERM HUP
      print -u2 -r -- "compress: archive appeared while compressing: $archive"
      return 1
    fi
    command mv -n -- "$temp_archive" "$archive"
    local -i move_status=$?
    if (( move_status )); then
      _compress_cleanup "$temp_archive" "$temp_dir"
      temp_archive=""
      temp_dir=""
      trap - EXIT INT TERM HUP
      return "$move_status"
    fi
    if [[ -e "$temp_archive" ]]; then
      _compress_cleanup "$temp_archive" "$temp_dir"
      temp_archive=""
      temp_dir=""
      trap - EXIT INT TERM HUP
      print -u2 -r -- "compress: refused to replace archive: $archive"
      return 1
    fi
  fi
  temp_archive=""
  command rmdir -- "$temp_dir" 2>/dev/null
  temp_dir=""
  trap - EXIT INT TERM HUP

  archive_bytes="$(command wc -c <"$archive")"
  local metrics source_size archive_size ratio
  metrics="$(command awk -v source="$source_bytes" -v archive="$archive_bytes" '
    function human(value, units, unit_index) {
      split("B KiB MiB GiB TiB PiB", units, " ")
      unit_index = 1
      while (value >= 1024 && unit_index < 6) { value /= 1024; unit_index++ }
      return unit_index == 1 ? sprintf("%.0f%s", value, units[unit_index]) : sprintf("%.2f%s", value, units[unit_index])
    }
    BEGIN {
      ratio = source > 0 ? sprintf("%.1f%% of source", archive * 100 / source) : "-"
      printf "%s\t%s\t%s\n", human(source), human(archive), ratio
    }
  ')"
  IFS=$'\t' read -r source_size archive_size ratio <<<"$metrics"

  _compact_home_path "$source"
  local source_display="$REPLY"
  _compact_home_path "$archive"
  print -r -- "Compressed: $source_display -> $REPLY"
  print -r -- "Files: $file_count"
  print -r -- "Source size: $source_size"
  print -r -- "Archive size: $archive_size"
  print -r -- "Ratio: $ratio"
  local -i elapsed_seconds=$(( SECONDS - start_seconds ))
  (( elapsed_seconds == 0 )) && print -r -- "Elapsed: <1s" || print -r -- "Elapsed: ${elapsed_seconds}s"
}

_extract_help() {
  cat <<'EOF'
Usage:
  extract [--force] ARCHIVE [DEST]
  extract -h | --help

Description:
  Extract a supported archive into DEST. Container archives default to a new
  directory named after ARCHIVE; single compressed files default to their
  decompressed filename in the current directory. Existing nonempty explicit
  destinations are refused unless --force is supplied. Supported formats are
  tar, tar.gz, tgz, tar.bz2, tar.xz, tar.zst, zip, 7z, gz, bz2, xz, and zst.

Options:
  --force       Allow extraction into an existing nonempty destination.
  -h, --help    Show this help menu.

Examples:
  extract release.tar.gz
  extract logs.zip /tmp/logs
  extract --force package.tar.zst ~/inspect/package
EOF
}

# toolbox: filesystem | Extract common archive formats safely.
# toolbox-args: [--force] ARCHIVE [DEST]
# toolbox-example: extract release.tar.gz
# toolbox-example: extract logs.zip /tmp/logs
extract() {
  emulate -L zsh

  local force=false
  local -a positional
  while (( $# )); do
    case "$1" in
      -h|--help)
        _extract_help
        return 0
        ;;
      --force)
        force=true
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -*)
        print -u2 -r -- "extract: unknown option: $1"
        print -u2 -r -- "Run 'extract --help' for usage."
        return 2
        ;;
      *)
        positional+=("$1")
        ;;
    esac
    shift
  done

  if (( ${#positional} < 1 || ${#positional} > 2 )); then
    print -u2 -r -- "extract: an archive and optional destination are required"
    print -u2 -r -- "Run 'extract --help' for usage."
    return 2
  fi

  local archive="${~positional[1]}"
  archive="${archive:A}"
  [[ -f "$archive" && -r "$archive" ]] || {
    print -u2 -r -- "extract: archive not found or unreadable: $archive"
    return 1
  }

  local archive_name="${archive:t}"
  local lower_name="${archive_name:l}"
  local format="" stem="" stream_format=false
  local -a required_tools
  case "$lower_name" in
    *.tar.gz)
      format="tar-gz"
      stem="${${archive_name%.*}%.*}"
      required_tools=(tar gzip)
      ;;
    *.tgz)
      format="tar-gz"
      stem="${archive_name%.*}"
      required_tools=(tar gzip)
      ;;
    *.tar.bz2)
      format="tar-bz2"
      stem="${${archive_name%.*}%.*}"
      required_tools=(tar bzip2)
      ;;
    *.tar.xz)
      format="tar-xz"
      stem="${${archive_name%.*}%.*}"
      required_tools=(tar xz)
      ;;
    *.tar.zst)
      format="tar-zst"
      stem="${${archive_name%.*}%.*}"
      required_tools=(tar zstd)
      ;;
    *.tar)
      format="tar"
      stem="${archive_name%.*}"
      required_tools=(tar)
      ;;
    *.zip)
      format="zip"
      stem="${archive_name%.*}"
      required_tools=(unzip)
      ;;
    *.7z)
      format="7z"
      stem="${archive_name%.*}"
      required_tools=(7z)
      ;;
    *.gz)
      format="gz"
      stream_format=true
      stem="${archive_name%.*}"
      required_tools=(gzip)
      ;;
    *.bz2)
      format="bz2"
      stream_format=true
      stem="${archive_name%.*}"
      required_tools=(bzip2)
      ;;
    *.xz)
      format="xz"
      stream_format=true
      stem="${archive_name%.*}"
      required_tools=(xz)
      ;;
    *.zst)
      format="zst"
      stream_format=true
      stem="${archive_name%.*}"
      required_tools=(zstd)
      ;;
    *)
      print -u2 -r -- "extract: unsupported archive format: $archive_name"
      return 2
      ;;
  esac

  local tool
  for tool in "${required_tools[@]}"; do
    if (( ! $+commands[$tool] )); then
      print -u2 -r -- "extract: $tool is required for $archive_name"
      return 1
    fi
  done

  [[ -n "$stem" ]] || stem="${archive_name}.extracted"
  local destination default_stream_destination=false
  if (( ${#positional} == 2 )); then
    destination="${positional[2]}"
  elif [[ "$stream_format" == true ]]; then
    destination="$PWD"
    default_stream_destination=true
  else
    destination="$PWD/$stem"
  fi
  destination="${~destination:A}"
  if [[ -e "$destination" && ! -d "$destination" ]]; then
    print -u2 -r -- "extract: destination is not a directory: $destination"
    return 1
  fi
  if [[ -d "$destination" && "$force" != true && "$default_stream_destination" != true &&
        -n "$(command find "$destination" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    print -u2 -r -- "extract: destination is not empty: $destination"
    print -u2 -r -- "Use --force to extract there anyway."
    return 1
  fi
  command mkdir -p -- "$destination" || return $?

  local output_file extraction_status=0
  case "$format" in
    tar)
      command tar -xf "$archive" -C "$destination" || extraction_status=$?
      ;;
    tar-gz)
      command tar -xzf "$archive" -C "$destination" || extraction_status=$?
      ;;
    tar-bz2)
      command tar -xjf "$archive" -C "$destination" || extraction_status=$?
      ;;
    tar-xz)
      command tar -xJf "$archive" -C "$destination" || extraction_status=$?
      ;;
    tar-zst)
      command tar --zstd -xf "$archive" -C "$destination" || extraction_status=$?
      ;;
    zip)
      command unzip -q "$archive" -d "$destination" || extraction_status=$?
      ;;
    7z)
      command 7z x -y "-o$destination" "$archive" || extraction_status=$?
      ;;
    gz|bz2|xz|zst)
      output_file="$destination/$stem"
      if [[ -e "$output_file" && "$force" != true ]]; then
        print -u2 -r -- "extract: output already exists: $output_file"
        return 1
      fi
      case "$format" in
        gz)  command gzip -dc "$archive" >"$output_file" || extraction_status=$? ;;
        bz2) command bzip2 -dc "$archive" >"$output_file" || extraction_status=$? ;;
        xz)  command xz -dc "$archive" >"$output_file" || extraction_status=$? ;;
        zst) command zstd -qdc "$archive" >"$output_file" || extraction_status=$? ;;
      esac
      if (( extraction_status )); then
        command rm -f -- "$output_file"
      fi
      ;;
  esac

  if (( extraction_status )); then
    print -u2 -r -- "extract: extraction failed: $archive_name"
    return "$extraction_status"
  fi
  print -r -- "Extracted: $archive -> $destination"
}

# toolbox: filesystem interactive | Choose and open a file with fzf and Vim.
# toolbox-example: fvfind
fvfind() {
  local file
  file=$(fzf-tmux --exact -p 80%,60% --preview 'bat --theme="gruvbox" --style=plain --color=always {}' --preview-window=right:50%)
  [ -n "$file" ] && vim "$file"
}

# toolbox: filesystem interactive | Choose and preview a file with fzf and bat.
# toolbox-example: fbfind
fbfind() {
  local file
  file=$(fzf-tmux --exact -p 80%,60% --preview 'bat --theme="gruvbox-dark" --style=plain --color=always {}' --preview-window=right:50%)
  [ -n "$file" ] && bat --theme="gruvbox-dark" --plain --color=always "$file"
}
