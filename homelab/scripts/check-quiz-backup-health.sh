#!/bin/bash
# check-quiz-backup-health: exits 1 if the restic repository in B2 can't
# be reached or fails an integrity check. Freshness is covered by the
# quiz-backup job's own mark-success alert.
source /home/elliot/.config/restic/quiz.env

fail() {
  logger -t quiz-backup-health "WARNING: $1"
  echo "WARNING: $1" >&2
  exit 1
}

restic check --read-data-subset=10% --quiet \
  || fail "restic check failed for the quiz-platform repository"

exit 0
