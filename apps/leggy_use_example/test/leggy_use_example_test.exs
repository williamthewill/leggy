defmodule LeggyUseExampleTest do
  use ExUnit.Case
  doctest LeggyUseExample

  test "greets the world" do
    assert LeggyUseExample.hello() == :world
  end
end
