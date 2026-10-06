#!/bin/bash
#
# Custom occ commands, run inside nextcloud-aio-nextcloud by AIO's own
# /run-exec-commands.sh (supervisord program "run-exec-commands"), which invokes
# whatever NEXTCLOUD_EXEC_COMMANDS contains once Apache is reachable. That is the
# hook upstream provides for exactly this -- see
# https://github.com/nextcloud/all-in-one/blob/main/Containers/nextcloud/entrypoint.sh
# -- so nothing here needs a forked entrypoint or a custom image.
#
# Bind-mounted read-only and referenced as `NEXTCLOUD_EXEC_COMMANDS=bash
# /nextcloud-exec-commands.sh` rather than inlined into the env var, so the script
# stays reviewable and diffable instead of being a YAML string.
#
# Runs as www-data. Must be idempotent: it executes on every container start.

set -euo pipefail

occ() { php /var/www/html/occ "$@"; }

# AIO waits for Apache before calling us, but not for the install/upgrade to
# finish, and occ refuses to do anything useful until it has.
until occ status 2>/dev/null | grep -q "installed: true"; do
    echo "exec-commands: waiting for Nextcloud install to finish..."
    sleep 5
done

# IMPORTANT: AIO's run-exec-commands.sh activates Collabora's config only in its
# else-branch, i.e. only when NEXTCLOUD_EXEC_COMMANDS is unset. Setting that var
# takes over the whole hook, so this call has to be repeated here or Collabora
# silently loses its WOPI config on every start.
#
# Guarded on the app actually being installed, and non-fatal either way. This script
# runs under `set -e`, and `richdocuments:activate-config` fails hard with "There are
# no commands defined in the richdocuments namespace" whenever COLLABORA_ENABLED is
# "yes" but the app is not on the instance -- on a first boot before it installs, or
# if the env var is set without the collabora profile. That failure used to abort the
# whole script, so the default apps, landing page, ClamAV limits, App Store setting
# and branding below all silently never ran, with nothing in the logs but the
# Collabora error. Anything added here should be similarly tolerant.
if [ "${COLLABORA_ENABLED:-}" = "yes" ]; then
    if occ app:list --enabled | grep -q 'richdocuments'; then
        # Same call upstream AIO makes (php/containers.json): discovery and WOPI
        # callbacks go to apache's internal HTTP listener (23973) by its docker
        # network alias, never through NC_DOMAIN. With NC_DOMAIN=localhost that name
        # would point at the calling container itself, and any other name would need a
        # certificate it can verify. Browsers still reach Collabora at
        # https://${NC_DOMAIN}, because Collabora builds those URLs from server_name.
        echo "exec-commands: activating Collabora config..."
        occ richdocuments:activate-config \
            --wopi-url='http://nextcloud-aio-apache.nextcloud-aio:23973' \
            --callback-url='http://nextcloud-aio-apache.nextcloud-aio:23973' \
            || echo "exec-commands: WARNING: richdocuments:activate-config failed, continuing"
    else
        echo "exec-commands: COLLABORA_ENABLED=yes but richdocuments is not installed, skipping its config"
    fi
fi

# ClamAV off: disable the antivirus app too. REMOVE_DISABLED_APPS=no (required, see
# .env) means AIO never disables it, and files_antivirus left enabled with no clamd
# behind it rejects every upload with "No connection to anti virus". Idempotent, and
# non-fatal when the app was never installed.
if [ "${CLAMAV_ENABLED:-}" != "yes" ]; then
    if occ app:list --enabled | grep -q '^  - files_antivirus:'; then
        echo "exec-commands: ClamAV is off, disabling files_antivirus..."
        occ app:disable files_antivirus || echo "exec-commands: WARNING: could not disable files_antivirus, continuing"
    fi
fi

# Talk on a localhost NC_DOMAIN: drop the hosted signaling server AIO registers.
# AIO registers it as https://$NC_DOMAIN/standalone-signaling/, and Nextcloud (PHP, so
# libcurl) calls that URL itself whenever a conversation is created or changes. libcurl
# resolves `localhost` and `*.localhost` to loopback without reading /etc/hosts, so
# inside this container the call lands on the container itself and every conversation
# create fails with "cURL error 7: Failed to connect to localhost:443". Browsers and
# the signaling container reach the endpoint fine, which is why this only shows up
# server-side. Without the server entry Talk uses its built-in signaling: calls work,
# suited to small groups, and call recording (which needs the hosted server) is off.
# AIO re-adds the entry on every start, so this runs every start as well.
case "${NC_DOMAIN:-}" in
    localhost|*.localhost)
        for server in $(occ talk:signaling:list --output=plain 2>/dev/null | sed -n 's/^ *server: //p'); do
            echo "exec-commands: NC_DOMAIN is ${NC_DOMAIN}, removing Talk signaling server ${server}..."
            occ talk:signaling:delete "$server" || echo "exec-commands: WARNING: could not remove ${server}, continuing"
        done
        ;;
esac

# The nc_aio_tools bind mount only puts the app on disk; Nextcloud still has to be
# told it exists. Replaces the one-time manual `occ app:enable` step.
if ! occ app:list --enabled | grep -q 'nc_aio_tools'; then
    echo "exec-commands: enabling nc_aio_tools..."
    occ app:enable nc_aio_tools
fi

# Replaces the former nextcloud-aio-post-install one-shot service. Applies to new
# AND existing accounts. Leave DEFAULT_QUOTA blank to skip entirely.
if [ -n "${DEFAULT_QUOTA:-}" ]; then
    echo "exec-commands: setting default quota to ${DEFAULT_QUOTA}..."
    occ config:app:set files default_quota --value="$DEFAULT_QUOTA"
    occ user:list | sed -n 's/^  - \([^:]*\):.*/\1/p' | while read -r user; do
        occ user:setting "$user" files quota "$DEFAULT_QUOTA"
    done
fi

# Default apps, in Anirban's stated priority order (PR #1 review). These have to be
# enabled for the custom styling to apply to them.
#
# Two mechanisms, deliberately both:
#   NEXTCLOUD_STARTUP_APPS installs these on a FRESH install only -- AIO runs that
#   list once, on first startup, so it does nothing for an instance that already
#   exists. This loop is what makes the set hold on every start, and it also
#   re-enables anything an admin turned off by accident.
#
# app:enable is a no-op when the app is already on, so this stays quiet in the
# normal case. Apps absent from disk are reported and skipped rather than failing
# the whole hook -- mail and previewgenerator come from the app store and need
# `occ app:install`, which needs outbound network and is NOT done here on purpose
# (a hook that reaches the internet on every container start is its own problem).
if [ -n "${NEXTCLOUD_DEFAULT_APPS:-}" ]; then
    for app in $(echo "$NEXTCLOUD_DEFAULT_APPS" | tr ',' ' '); do
        if ! occ app:list --enabled | grep -q "^  - ${app}:"; then
            if occ app:enable "$app" >/dev/null 2>&1; then
                echo "exec-commands: enabled ${app}"
            else
                echo "exec-commands: ${app} not present on disk, skipping (occ app:install ${app} to add it)"
            fi
        fi
    done

    # Landing page. `defaultapp` is a comma-separated fallback chain, first ENABLED
    # entry wins, so the same priority order works directly. Note this only controls
    # where users land: the order of icons in the top bar is a per-user setting
    # (core/apporder) with no admin-level default, so it cannot be set from here.
    occ config:system:set defaultapp --value="$NEXTCLOUD_DEFAULT_APPS"
fi

# App Store, off by default (Anirban's request). This hides the "Apps" admin section
# and stops the server reaching out to apps.nextcloud.com, so the only apps on the
# instance are the ones this compose file ships. Note it does not disable or remove
# anything already installed, and updates to installed apps stop arriving too -- with
# the store off, `occ app:update` has no source to pull from, so app upgrades become
# part of bumping the image tag rather than something an admin does in the UI.
#
# Set NEXTCLOUD_APPSTORE_ENABLED=yes in .env to put it back. Installing an app while
# it is off means turning it on, installing, and turning it off again.
if [ "${NEXTCLOUD_APPSTORE_ENABLED:-no}" = "yes" ]; then
    echo "exec-commands: App Store enabled"
    occ config:system:set appstoreenabled --value=true --type=boolean
else
    echo "exec-commands: disabling the App Store..."
    occ config:system:set appstoreenabled --value=false --type=boolean
fi

# BharatSuite branding.
#
# Only the text and colour keys go through occ -- `theming:config` accepts name, url,
# imprintUrl, privacyUrl, slogan, color, primary_color, background_color and
# disable-user-theming, and rejects the image keys even though it prints them. The
# logo, header logo and favicon are therefore NOT set here: they are served from the
# nc_aio_tools app and assigned to Nextcloud's own --image-logo / --image-logoheader
# variables in css/bharatsuite.css, which keeps them in version control instead of
# inside a Docker volume.
#
# BRANDING_SLOGAN is intentionally allowed to be empty: an unset slogan renders
# nothing, which is correct until real copy exists. Do not put placeholder text here,
# it shows on the login screen.
if [ -n "${BRANDING_NAME:-}" ]; then
    echo "exec-commands: applying ${BRANDING_NAME} branding..."
    occ theming:config name "$BRANDING_NAME"
    [ -n "${BRANDING_PRIMARY_COLOR:-}" ] && occ theming:config primary_color "$BRANDING_PRIMARY_COLOR"
    [ -n "${BRANDING_BACKGROUND_COLOR:-}" ] && occ theming:config background_color "$BRANDING_BACKGROUND_COLOR"
    [ -n "${BRANDING_URL:-}" ] && occ theming:config url "$BRANDING_URL"
    # Blank the slogan by SETTING an empty string, never by --reset. ThemingDefaults
    # ::getSlogan() falls back to Nextcloud's own default when the key is absent, so
    # resetting puts "a safe home for all your data" back on the login screen.
    occ theming:config slogan "${BRANDING_SLOGAN:-}"

    # Login background. Without this the stock Nextcloud blue artwork stays, whatever
    # the colours are set to: theming only paints the plain background_color when
    # backgroundMime is the literal 'backgroundColor'. There is no theming:config key
    # for it, hence config:app:set.
    occ config:app:set theming backgroundMime --value=backgroundColor >/dev/null
fi

# ClamAV scan limits (Anirban's request: 10 MB).
#
# NOTE: the MAX_SIZE env var on nextcloud-aio-clamav is INERT -- that image's
# /start.sh never reads it, and its clamd.conf ships hardcoded 2000M values. The
# limits Nextcloud actually enforces are these two files_antivirus app settings, so
# this is the only place setting them has any effect.
#   av_max_file_size     -- files larger than this are skipped entirely (-1 = no cap)
#   av_stream_max_length -- how much of a file is streamed to clamd
# Both are bytes. Files above the cap are accepted by Nextcloud WITHOUT being
# scanned, so raising it trades throughput for coverage.
#
# Only when ClamAV is on. With it off the app is disabled above, and running this
# anyway wrote antivirus settings and logged "capping ClamAV scanning" on every start,
# which reads as a scan still running.
if [ "${CLAMAV_ENABLED:-}" = "yes" ] && [ -n "${CLAMAV_MAX_FILE_SIZE:-}" ]; then
    echo "exec-commands: capping ClamAV scanning at ${CLAMAV_MAX_FILE_SIZE} bytes..."
    occ config:app:set files_antivirus av_max_file_size --value="$CLAMAV_MAX_FILE_SIZE"
    occ config:app:set files_antivirus av_stream_max_length --value="$CLAMAV_MAX_FILE_SIZE"
fi

# Nextcloud's own application log (JSON, one object per line) on this container's
# stdout, so `docker logs` shows it, in ADDITION to the file the Log Reader UI reads.
# AIO's only built-in way to reach stdout is NEXTCLOUD_LOG_TYPE=errorlog, which
# replaces the file and leaves the UI with nothing to show, so the file stays and is
# followed instead. This script exits when it is done but its stdout is the
# supervisord pipe for this program, which run-exec-commands.sh keeps open for the
# life of the container, so a background tail started here keeps writing to it.
# -n 0: only new entries, because stdout already keeps earlier runs of this container.
# With log_type=errorlog (NEXTCLOUD_LOG_TYPE) the entries are on stderr already, skip.
if [ "$(occ config:system:get log_type 2>/dev/null)" = "file" ]; then
    app_logfile="$(occ config:system:get logfile 2>/dev/null)"
    stream_pid_file=/tmp/nextcloud-log-stream.pid
    if [ -n "$app_logfile" ]; then
        # /tmp survives a plain container restart while PIDs start over, so a bare
        # `kill -0` on the saved PID could hit an unrelated process and skip the stream.
        # Check that the PID is really our tail.
        stream_pid="$(cat "$stream_pid_file" 2>/dev/null || true)"
        if [ -n "$stream_pid" ] && tr '\0' ' ' < "/proc/$stream_pid/cmdline" 2>/dev/null | grep -qF "tail -n 0 -F $app_logfile"; then
            echo "exec-commands: Nextcloud log already streaming to stdout"
        else
            touch "$app_logfile" 2>/dev/null || true
            tail -n 0 -F "$app_logfile" &
            echo $! > "$stream_pid_file"
            echo "exec-commands: streaming ${app_logfile} to stdout"
        fi
    fi
fi

echo "exec-commands: done."
