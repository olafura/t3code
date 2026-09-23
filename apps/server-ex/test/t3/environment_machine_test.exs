defmodule T3.Environment.MachineTest do
  use ExUnit.Case, async: true

  alias T3.Environment.Machine

  test "Apple names, DMI chassis types, and VMs map to icon kinds" do
    assert Machine.apple("Mac mini (2024)") == "mac-mini"
    assert Machine.apple("Macmini8,1") == "mac-mini"
    assert Machine.apple("MacBookPro18,3") == "laptop"
    assert Machine.apple("ThinkPad") == nil

    assert Machine.from_dmi("23", "Dell Inc.", "PowerEdge R640") == "server"
    assert Machine.from_dmi("10", "LENOVO", "ThinkPad X1") == "laptop"
    # A VM is "cloud" whatever chassis the hypervisor fakes; Asahi keeps the Apple name.
    assert Machine.from_dmi("3", "QEMU", "Standard PC (Q35)") == "cloud"
    assert Machine.from_dmi(nil, "Apple Inc.", "Mac Studio (M2 Max)") == "mac-studio"
    assert Machine.from_dmi("2", nil, nil) == nil
  end
end
