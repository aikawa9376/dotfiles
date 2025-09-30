return {
  "chrisgrieser/nvim-recorder",
  keys = {
    { "@", desc = " Start Recording" },
    { "@@", desc = " Play Recording" },
    { "q", "<nop>", desc = "Disabled (use nvim-recorder instead)" },
  },
  opts = {
    mapping = {
      startStopRecording = "@",
      playMacro = "@@",
      switchSlot = "<C-@>",
      editMacro = "c@",
      deleteAllMacros = "d@",
      yankMacro = "y@",
      addBreakPoint = "##",
    },
  }
}
