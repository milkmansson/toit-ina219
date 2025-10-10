// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import gpio
import i2c
import ina219 show *

/**
Triggered Updates Example:

This use case is relevant where a balance is required between Update Speed and
 Accuracy - eg in a Battery-Powered Scenario.  The INA226 is used to monitor the
 node’s power draw to be able to estimate battery life.  Instead of running in
 continuous conversion mode use triggered (single-shot) mode with longer
 conversion times and averaging enabled.
*/

main:
  frequency := 400_000
  sda   := gpio.Pin 26
  scl   := gpio.Pin 25
  bus   := i2c.Bus --sda=sda --scl=scl --frequency=frequency
  event := 0

  ina219-device := bus.device Ina219.I2C_ADDRESS
  ina219-driver := Ina219 ina219-device --shunt-resistor=0.100

  // Set sample size to smallest to help show variation in voltage is noticable.
  // Be aware that sample sizing and conversion timing are fixed in pairs.
  ina219-driver.set-bus-adc-resolution-average Ina219.ADC-RES-AVG-M9-84
  ina219-driver.set-shunt-adc-resolution-average Ina219.ADC-RES-AVG-M9-84

  // Also in this example, we set the PGA Gain/Range as if our loads are very small
  ina219-driver.set-shunt-voltage-pga-gain-range Ina219.SHUNT-VOLTAGE-PGA-G1-R40

  // Read and display values every minute, but turn the device off in between.
  10.repeat:
    // Three CONTINUOUS measurements, fluctuation expected.
    ina219-driver.set-measure-mode Ina219.MODE-SHUNT-BUS-CONTINUOUS
    print "Three CONTINUOUS measurements, fluctuation usually expected."
    3.repeat:
      print "      READ $(%02d it + 1): $(%0.2f (ina219-driver.read-shunt-current * 1000.0))ma  $(%0.4f (ina219-driver.read-supply-voltage))v  $(%0.1f (ina219-driver.read-load-power * 1000.0))mw"
      sleep --ms=500

    // CHANGE MODE - trigger a measurement and switch off.
    3.repeat:
      ina219-driver.set-measure-mode Ina219.MODE-SHUNT-BUS-TRIGGERED
      ina219-driver.trigger-measurement
      ina219-driver.set-measure-mode Ina219.MODE-POWER-DOWN
      event = it
      print " TRIGGER EVENT #$(%02d event + 1) - Registers read 3 times (new values, but no change between reads)."

      3.repeat:
        print "  #$(%02d event + 1) READ $(%02d it): $(%0.2f (ina219-driver.read-shunt-current * 1000.0))ma  $(%0.3f (ina219-driver.read-supply-voltage))v  $(%0.1f (ina219-driver.read-load-power * 1000.0))mw"
        sleep --ms=500

    print "Waiting 30 seconds"
    print ""
    sleep (Duration --s=30)
