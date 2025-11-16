package imgui_impl_raylib

import ImGui "../odin-imgui"
import "../odin-imgui/imgui_impl_glfw"
import "../odin-imgui/imgui_impl_opengl3"
import "vendor:glfw"
foreign { // glfw functions manually added to circumvent linker conflicts with raylib (only used for imgui)
  glfwMakeContextCurrent :: proc(window: rawptr) ---
  glfwGetCurrentContext  :: proc() -> rawptr ---
}

init :: proc() {
  ImGui.CHECKVERSION()
  ImGui.CreateContext()
  io := ImGui.GetIO()
  // io.ConfigFlags += { .NavEnableKeyboard, .NavEnableGamepad }
  io.ConfigFlags += { .DockingEnable }
  // io.ConfigFlags += { .ViewportsEnable }

  style := ImGui.GetStyle()
  style.WindowRounding = 0
  style.Colors[ImGui.Col.WindowBg].w =1
  ImGui.StyleColorsDark()
  imgui_impl_glfw.InitForOpenGL(glfw.WindowHandle(glfwGetCurrentContext()), true)
  imgui_impl_opengl3.Init("#version 330")
}

new_frame :: proc() -> (dockspace_id: ImGui.ID) {
  imgui_impl_opengl3.NewFrame()
  imgui_impl_glfw.NewFrame()
  ImGui.NewFrame()
  return ImGui.DockSpaceOverViewport(0, ImGui.GetMainViewport(), { .PassthruCentralNode });
}

render :: proc() {
  ImGui.Render()
  imgui_impl_opengl3.RenderDrawData(ImGui.GetDrawData())
  backup_current_window := glfwGetCurrentContext()
  ImGui.UpdatePlatformWindows()
  ImGui.RenderPlatformWindowsDefault()
  glfwMakeContextCurrent(backup_current_window)
}
