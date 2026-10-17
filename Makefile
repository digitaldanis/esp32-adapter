BUILD := build/tests
CFLAGS := -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -Ifirmware/main

.PHONY: test firmware image clean

test: $(BUILD)/test_h4 $(BUILD)/test_voice
	$(BUILD)/test_h4
	$(BUILD)/test_voice && echo "PASS: voice-setting rewrite"
	python3 -m unittest discover -s tests -p 'test_*.py'

$(BUILD)/test_h4: tests/test_h4.c firmware/main/h4_parser.c firmware/main/h4_parser.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ tests/test_h4.c firmware/main/h4_parser.c

$(BUILD)/test_voice: tests/test_voice.c firmware/main/hci_compat.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ tests/test_voice.c

# Needs an activated ESP-IDF v5.5 environment (. $IDF_PATH/export.sh).
firmware:
	cd firmware && idf.py build

# Single image for offset 0x0: bootloader, partition table and app.
image: firmware
	cd firmware/build && python3 -m esptool --chip esp32 merge-bin \
		--flash-mode dio --flash-freq 40m --flash-size 4MB \
		-o ../../esp32-airbridge-full.bin @flash_args

clean:
	rm -rf build firmware/build firmware/sdkconfig esp32-airbridge-full.bin
