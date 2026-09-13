#!/bin/bash
set -e

# wait for Nextcloud to be ready first, then run the PHP commands
(
  until curl -sf http://localhost/status.php > /dev/null 2>&1; do
    sleep 3
  done

  #migrate the mimetypes
  php /var/www/html/occ maintenance:repair --include-expensive || true

  #remove the limits and rate limiting on the calender
  php /var/www/html/occ config:app:set dav maximumCalendarsSubscriptions --type=integer --value=-1 || true
  php /var/www/html/occ config:app:set dav rateLimitPeriodCalendarCreation --type=integer --value=1 || true
  php /var/www/html/occ config:app:set dav rateLimitCalendarCreation --type=integer --value=1000 || true

  #make the calender not automatically set the status to meeting mode
  php occ config:app:set dav disableFreeBusy --value yes
) &

# Hand off to Nextcloud's normal entrypoint
exec /entrypoint.sh apache2-foreground
