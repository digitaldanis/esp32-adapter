/* ESP32 AirBridge: H4 over the board's CP2102/UART0; Bluetooth is handled by BlueZ.
 * No Wi-Fi, transcoding, audio buffering or diagnostic text on the transport.
 * Original ESP32 only; UART0 TX=1 RX=3, 921600 8N1, no CTS/RTS wiring available.
 */
#include <stdbool.h>
#include <string.h>
#include <stdint.h>
#include <stdatomic.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/ringbuf.h"
#include "driver/uart.h"
#include "esp_bt.h"
#include "esp_err.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "h4_parser.h"
#include "hci_compat.h"

static RingbufHandle_t to_host;
static QueueHandle_t uart_events;
static TaskHandle_t rx_task_handle;
static atomic_bool fault;
static h4_parser_t parser;

/* The controller defaults to 0..+3 dBm on BR/EDR. A2DP at full SBC bitpool sends a
 * 3-DH5 packet every ~21 ms with no slack, so any retransmission burst (USB 3 noise,
 * a phone nearby) stalled completions for ~200 ms in btmon and dropped audio.
 * Use the chip's full +9 dBm, with a +6 dBm floor so power control cannot back off far. */
static esp_err_t set_bredr_tx_power(void) {
    return esp_bredr_tx_power_set(ESP_PWR_LVL_P6, ESP_PWR_LVL_P9);
}
static void host_send_available(void) {
    if (rx_task_handle) xTaskNotifyGive(rx_task_handle);
}
static int controller_packet(uint8_t *data, uint16_t length) {
    if (atomic_load(&fault)) return -1;
    /* Use the legacy SCO setup path on this controller. Linux otherwise chooses
     * Enhanced Setup/Accept Sync, which establishes a link but delivered only
     * zero-filled incoming SCO data in the hardware test. Clear capabilities;
     * never synthesize command acknowledgements or packet completions. */
    if (length >= 71 && data[0] == 4 && data[1] == 0x0e &&
        data[4] == 0x02 && data[5] == 0x10 && data[6] == 0)
        data[7 + 29] &= (uint8_t)~0x18;
    /* The VHCI callback must not block the controller task. Copy before returning. */
    if (!length || length > H4_MAX_PACKET ||
        xRingbufferSend(to_host, data, length, 0) != pdTRUE) {
        atomic_store(&fault, true);
        return -1;
    }
    return 0;
}
static bool send_controller(const uint8_t *data, size_t length, void *unused) {
    (void)unused;
    uint8_t voice_command[32];
    if (length <= sizeof(voice_command)) {
        memcpy(voice_command, data, length);
        if (airbridge_fix_voice(voice_command, length)) data = voice_command;
    }
    while (!esp_vhci_host_check_send_available()) {
        if (atomic_load(&fault) || !ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(2000))) return false;
    }
    if (atomic_load(&fault)) return false;
    /* Linux resets/reconfigures the controller after boot. Reassert the voice
     * path immediately before SCO establishment, as Espressif's HFP host does.
     * Keep this API call in our UART task, outside the controller callback. */
    if (length >= 4 && data[0] == 1) {
        uint16_t opcode = data[1] | ((uint16_t)data[2] << 8);
        if (opcode == 0x0428 || opcode == 0x0429 ||
            opcode == 0x043d || opcode == 0x043e) {
            if (esp_bredr_sco_datapath_set(ESP_SCO_DATA_PATH_HCI) != ESP_OK)
                return false;
        }
        /* Same for TX power: reassert before page scan or a new ACL link starts. */
        if (opcode == 0x0c1a || opcode == 0x0405 || opcode == 0x0409) {
            if (set_bredr_tx_power() != ESP_OK) return false;
        }
    }
    esp_vhci_host_send_packet((uint8_t *)data, (uint16_t)length);
    return true;
}
static void receive_uart(void *unused) {
    (void)unused;
    uart_event_t event;
    uint8_t buffer[256];
    TickType_t last_rx = xTaskGetTickCount();
    while (true) {
        if (xQueueReceive(uart_events, &event, pdMS_TO_TICKS(250)) != pdTRUE) {
            if (parser.used && xTaskGetTickCount() - last_rx > pdMS_TO_TICKS(500))
                atomic_store(&fault, true);
            continue;
        }
        if (event.type == UART_FIFO_OVF || event.type == UART_BUFFER_FULL ||
            event.type == UART_PARITY_ERR || event.type == UART_FRAME_ERR || event.type == UART_BREAK) {
            atomic_store(&fault, true);
            continue;
        }
        if (event.type != UART_DATA || atomic_load(&fault)) continue;
        size_t remaining = event.size;
        while (remaining) {
            size_t chunk = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
            int n = uart_read_bytes(UART_NUM_0, buffer, chunk, pdMS_TO_TICKS(100));
            if (n <= 0 || !h4_feed(&parser, buffer, (size_t)n, send_controller, NULL)) {
                atomic_store(&fault, true);
                break;
            }
            remaining -= (size_t)n;
            last_rx = xTaskGetTickCount();
        }
    }
}
static void transmit_uart(void *unused) {
    (void)unused;
    while (true) {
        if (atomic_load(&fault)) {
            /* Report Hardware Error to Linux, then reboot silently. Never continue a corrupt stream. */
            const uint8_t error[] = {0x04, 0x10, 0x01, 0x01};
            uart_write_bytes(UART_NUM_0, error, sizeof(error));
            uart_wait_tx_done(UART_NUM_0, pdMS_TO_TICKS(500));
            vTaskDelay(pdMS_TO_TICKS(200));
            esp_restart();
        }
        size_t length = 0;
        uint8_t *data = xRingbufferReceive(to_host, &length, pdMS_TO_TICKS(20));
        if (!data) continue;
        if (uart_write_bytes(UART_NUM_0, data, length) != (int)length) atomic_store(&fault, true);
        vRingbufferReturnItem(to_host, data);
    }
}
void app_main(void) {
    /* Do not auto-erase NVS on failure: preserve calibration and avoid hiding flash errors. */
    ESP_ERROR_CHECK(nvs_flash_init());
    const uart_config_t cfg = {.baud_rate = 921600, .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE, .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE, .source_clk = UART_SCLK_DEFAULT};
    ESP_ERROR_CHECK(uart_param_config(UART_NUM_0, &cfg));
    ESP_ERROR_CHECK(uart_set_pin(UART_NUM_0, 1, 3, UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));
    ESP_ERROR_CHECK(uart_driver_install(UART_NUM_0, 8192, 8192, 32, &uart_events, 0));
    ESP_ERROR_CHECK(uart_set_rx_full_threshold(UART_NUM_0, 64));
    ESP_ERROR_CHECK(uart_set_rx_timeout(UART_NUM_0, 2));
    to_host = xRingbufferCreate(32768, RINGBUF_TYPE_NOSPLIT);
    if (!to_host) esp_restart();
    h4_reset(&parser);
    esp_bt_controller_config_t controller = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_bt_controller_init(&controller));
    static const esp_vhci_host_callback_t callbacks = {.notify_host_send_available = host_send_available,
        .notify_host_recv = controller_packet};
    ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_BTDM));
    ESP_ERROR_CHECK(set_bredr_tx_power());
    ESP_ERROR_CHECK(esp_vhci_host_register_callback(&callbacks));
    ESP_ERROR_CHECK(esp_bredr_sco_datapath_set(ESP_SCO_DATA_PATH_HCI));
    if (xTaskCreatePinnedToCore(transmit_uart, "h4-tx", 3072, NULL, 19, NULL, 1) != pdPASS ||
        xTaskCreatePinnedToCore(receive_uart, "h4-rx", 4096, NULL, 18, &rx_task_handle, 1) != pdPASS)
        esp_restart();
}
