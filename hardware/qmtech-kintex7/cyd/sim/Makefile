# Build and run the CYD host/firmware unit tests.
#
# These tests compile firmware and host sources on the HOST without
# Arduino/TFT_eSPI dependencies so the entire state machine, parsers,
# math, and form validation can be exercised in simulation.

CC      ?= gcc
H        = ../host
F        = ../firmware/include
S        = ../firmware/src
CFLAGS  ?= -std=c11 -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE -Wall -Wextra \
           -Wno-unused-parameter -O1 -g
CPPFLAGS = -I$(H) -I$(F) -I. -I$(SW)
SW       = ../../sw

TESTS = test_cyd_cmd test_cyd_md5 test_cyd_ota_send \
        test_cyd_status_parse test_cyd_fmt test_cyd_ui \
        test_webd_form test_pow_math test_cyd_wifi_flow \
        test_share_recover test_reset_watch

.PHONY: all check clean
all: $(TESTS)

check: $(TESTS)
	@# test_pow_math.c TRANSCRIBES target_met() and hash_to_difficulty()
	@# because both are static in miner_pipe_am01.c and linking that would
	@# drag in libgpiod and the stratum client. A copy that drifts passes for
	@# ever while the miner changes underneath it, and those two functions
	@# decide whether a share is valid -- so the copy is checked, not trusted.
	@echo "-- PoW maths copies --"; python3 check_pow_copy.py || exit 1
	@fail=0; for t in $(TESTS); do \
	  if ./$$t >/dev/null 2>&1; then echo "PASS $$t"; \
	  else echo "FAIL $$t"; ./$$t 2>&1 | tail -20; fail=1; fi; \
	done; exit $$fail

# Miner-side logic, kept here because test_pow_math already is: this is where
# host-side unit tests live, whatever part of the tree they cover.
test_share_recover:    test_share_recover.c    $(SW)/share_recover.c
test_reset_watch:      test_reset_watch.c      $(SW)/reset_watch.c

test_cyd_cmd:          test_cyd_cmd.c          $(H)/cyd_cmd.c
test_cyd_md5:          test_cyd_md5.c          $(H)/cyd_md5.c
test_cyd_ota_send:     test_cyd_ota_send.c     $(H)/cyd_ota_send.c $(H)/cyd_md5.c
test_cyd_status_parse: test_cyd_status_parse.c $(S)/cyd_status_parse.c
test_cyd_fmt:          test_cyd_fmt.c          $(S)/cyd_fmt.c $(S)/cyd_status_parse.c
test_cyd_ui:           test_cyd_ui.c           $(S)/cyd_ui.c $(S)/cyd_fmt.c \
                                               $(S)/cyd_status_parse.c
test_webd_form:        test_webd_form.c
test_pow_math:         test_pow_math.c
test_cyd_wifi_flow:    test_cyd_wifi_flow.c    $(S)/cyd_ui.c $(S)/cyd_fmt.c \
                                               $(S)/cyd_status_parse.c

$(TESTS):
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ $^ -lm

clean:
	rm -f $(TESTS)
