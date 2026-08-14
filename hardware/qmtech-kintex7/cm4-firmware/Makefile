# AtomMiner AM01 -- QMTECH Kintex-7 + Raspberry Pi CM4 variant, design proposal
# Copyright 2015-2022 AtomMiner <atom@atomminer.com>
#
# Requires libgpiod's C library + headers, e.g. on Raspberry Pi OS:
#   sudo apt install libgpiod-dev gpiod

CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -std=gnu11
LDLIBS  := -lgpiod

BIN := am01_bus_test
OBJS := am01_bus_test.o am01_gpio_bus.o

all: $(BIN)

$(BIN): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

%.o: %.c am01_gpio_bus.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(BIN)

.PHONY: all clean
