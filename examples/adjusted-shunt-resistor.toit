// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import gpio
import i2c
import ina219 show *

/*
Use Case: Changing the scale of currents measured

If the task is to measure much smaller standby or sleep currents (eg, in the
milliamp range) the default shunt resistor could be replaced with a larger value
resistor (e.g.  1.0 Ohm).  This would increase the voltage drop per milliamp,
giving the INA219 finer resolution for small loads.  The consequence is that the
maximum measurable current would shrink while more power would be dissipated in
the shunt as heat.

Please see the README.md for example Shunt Resistor values.
*/

main:
  // Adjust these to pin numbers in your setup.
  sda := gpio.Pin 26
  scl := gpio.Pin 25

  frequency := 400_000
  bus := i2c.Bus --sda=sda --scl=scl --frequency=frequency
  ina219-device := bus.device Ina219.I2C_ADDRESS

  // Creates instance using an 0.010 Ohm shunt resistor
  ina219-driver := Ina219 ina219-device --shunt-resistor=0.010

  // Is the default, but setting again in case of consecutive tests without reset
  ina219-driver.set-measure-mode Ina219.MODE-SHUNT-BUS-CONTINUOUS

  // Set the full scale range to 16volts, reducing maximum but increasing
  // sensitivity of small loads.
  ina219-driver.set-bus-voltage-fs-range 16

  // Continuously read and display values, in one row:
  shunt-current/float := 0.0
  bus-voltage/float      := 0.0
  load-power/float    := 0.0
  10.repeat:
    shunt-current = ina219-driver.read-shunt-current * 1000.0
    bus-voltage = ina219-driver.read-bus-voltage
    load-power = ina219-driver.read-load-power * 1000
    print "  $(%0.1f shunt-current)ma  $(%0.3f bus-voltage)v  $(%0.1f load-power)mw"
    sleep --ms=500
