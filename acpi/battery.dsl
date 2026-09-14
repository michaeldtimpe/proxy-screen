DefinitionBlock ("", "SSDT", 2, "PSCRN", "BATT", 0x00000001)
{
    Scope (\_SB)
    {
        Device (ADP0)
        {
            Name (_HID, "ACPI0003")
            Method (_STA, 0) { Return (0x0F) }
            Method (_PSR, 0) { Return (One) }
            Method (_PCL, 0) { Return (Package(){ \_SB }) }
        }
        Device (BAT0)
        {
            Name (_HID, EisaId ("PNP0C0A"))
            Name (_UID, One)
            Method (_STA, 0) { Return (0x1F) }
            Method (_BIF, 0) { Return (Package (0x0D) { One, 0x2710, 0x2710, One, 0x2EE0, 0x03E8, 0x01F4, 0x64, 0x64, "BAT0", "0001", "LION", "PSCRN" }) }
            Method (_BST, 0) { Return (Package (0x04) { Zero, 0x03E8, 0x2328, 0x2EE0 }) }
        }
    }
}
