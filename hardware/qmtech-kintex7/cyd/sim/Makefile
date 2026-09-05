# Build and run the CYD host/firmware unit tests.
#
# These tests existed with no build rules -- every one had to be rebuilt by
# hand, guessing its object set from the linker errors. That is how test
# suites quietly stop being run. `make -C cyd/sim` is now the whole story.
#
# They compile firmware sources (cyd_ui.c, cyd_fmt.c, cyd_status_parse.c) on
# the HOST on purpose: that logic is deliberately free of Arduino/TFT_eSPI
# dependencies so it can be tested without hardware. cyd_ui_draw.cpp is the
# part that touches the display, and it is not here for exactly that reason.

CC      ?= gcc
H        = ../host
F        = ../firmware/include
S        = ../firmware/src
# _POSIX_C_SOURCE: cyd_ota_send.c uses fileno(), which is POSIX, not C11.
CFLAGS  ?= -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra \
           -Wno-unused-parameter -O1 -g
CPPFLAGS = -I$(H) -I$(F) -I.

TESTS = test_cyd_cmd test_cyd_md5 test_cyd_ota_send \
        test_cyd_status_parse test_cyd_fmt test_cyd_ui

.PHONY: all check clean
all: $(TESTS)

check: $(TESTS)
	@fail=0; for t in $(TESTS); do \
	  if ./$$t >/dev/null 2>&1; then echo "PASS $$t"; \
	  else echo "FAIL $$t"; ./$$t 2>&1 | tail -20; fail=1; fi; \
	done; exit $$fail

test_cyd_cmd:          test_cyd_cmd.c          $(H)/cyd_cmd.c
test_cyd_md5:          test_cyd_md5.c          $(H)/cyd_md5.c
test_cyd_ota_send:     test_cyd_ota_send.c     $(H)/cyd_ota_send.c $(H)/cyd_md5.c
test_cyd_status_parse: test_cyd_status_parse.c $(S)/cyd_status_parse.c
test_cyd_fmt:          test_cyd_fmt.c          $(S)/cyd_fmt.c $(S)/cyd_status_parse.c
test_cyd_ui:           test_cyd_ui.c           $(S)/cyd_ui.c $(S)/cyd_fmt.c \
                                               $(S)/cyd_status_parse.c

$(TESTS):
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ $^

clean:
	rm -f $(TESTS)
