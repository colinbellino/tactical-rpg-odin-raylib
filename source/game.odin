package game

import "core:c"
import "core:container/queue"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:math/linalg/glsl"
import "core:os/os2"
import "core:strings"
import "core:time"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import ImGui "../vendor/odin-imgui"
import imgui_rl "../vendor/imgui_impl_raylib"

EMBED_ASSETS :: #config(EMBED_ASSETS, false)
COLOR_CLEAR :: rl.Color{ 0, 0, 0, 255 }
TILE_STEP_HEIGHT :: 0.25
TILE_OFFSET :: Vector3f32{ 0.5, 0, 0.5 }
LEVEL_NAME :: "level0.json"
game: Game_State

Game_State :: struct {
  mode:           Game_Mode,
  texture_dirt:   rl.Texture,
  camera:         rl.Camera3D,
  level_data:     Level_Data,
  world_scale:    f32,
  world_rotation: f32,
  move_repeater:  Input_Repeater,
  level_editor:   Level_Editor,
  battle:         Battle,
}
Vector2f32 :: [2]f32
Vector3f32 :: [3]f32
Vector2i32 :: [2]i32
Vector3i32 :: [3]i32
Game_Mode :: enum { TITLE, BATTLE, LEVEL_EDITOR }
Level_Editor :: struct {
  level_name:       string,
  marker_position:  Vector2i32,
  marker_size:      Vector2i32,
}
Battle :: struct {
  mode:             Mode(Battle_Mode),
  marker_position:  Vector2i32,
  marker_visible:   bool,
  board:            Board,
  selected_tiles:   [dynamic]Vector2i32 // TODO: allocate this in the turn arena
}
Battle_Mode :: enum { INIT, MOVE_TARGET }

main :: proc() {
  context.logger = log.create_console_logger()

  rl.SetConfigFlags({ .WINDOW_RESIZABLE, .VSYNC_HINT })
  rl.InitWindow(1920, 1080, "Tactics RPG (Odin + Raylib)")
  rl.SetTargetFPS(60)

  imgui_rl.init()

  game.world_scale = 1
  game.move_repeater.threshold = 200 * time.Millisecond
  game.move_repeater.rate      = 100 * time.Millisecond
  level_read_from_disk(&game.level_data, LEVEL_NAME)
  game.camera.position   = { 0, 4, 0 }
  game.camera.target     = { 0, 0, 0 }
  game.camera.up         = { 0, 1, 0 }
  game.camera.fovy       = 14
  game.camera.projection = .ORTHOGRAPHIC
  game.camera.target     = { f32(LEVEL_SIZE.x)*0.5, 0, f32(LEVEL_SIZE.y)*0.5 }

  when EMBED_ASSETS {
    game.texture_dirt = load_texture_from_memory(#load("../assets/Dirt.png"))
  } else {
    game.texture_dirt = rl.LoadTexture("assets/Dirt.png")
  }

  for !rl.WindowShouldClose() {
    imgui_rl.new_frame()

    rl.BeginDrawing()
    rl.ClearBackground(COLOR_CLEAR)

    { // debug menu
      {
        if rl.IsKeyPressed(.F1) { game.mode = .BATTLE }
        if rl.IsKeyPressed(.F2) { game.mode = .LEVEL_EDITOR }
      }
      if ImGui.BeginMainMenuBar() {
        defer ImGui.EndMainMenuBar()
        if ImGui.BeginMenu("Window") {
          defer ImGui.EndMenu()
          if ImGui.MenuItem("Battle", "F1", game.mode == .BATTLE) {
            game.mode = .BATTLE
          }
          if ImGui.MenuItem("Level editor", "F2", game.mode == .LEVEL_EDITOR) {
            game.mode = .LEVEL_EDITOR
          }
        }
      }
    }

    switch game.mode {
      case .TITLE: {
        ImGui.Text("- Start battle:      F1")
        ImGui.Text("- Open level editor: F2")
      }
      case .BATTLE: {
        battle := &game.battle

        { // keyboard inputs
          input_repeater_update_keyboard(&game.move_repeater, .LEFT, .RIGHT, .UP, .DOWN)
        }

        ImGui.SetNextWindowSize({ 350, 700 }, .Once)
        if ImGui.Begin("Battle") {
          defer ImGui.End()

          ImGui.Text(fmt.ctprintf("Current mode: %v", battle.mode.current))

          ImGui.Text("Transition to:")
          if ImGui.Button("INIT")        { mode_transition(&battle.mode, Battle_Mode.INIT) }
          if ImGui.Button("MOVE_TARGET") { mode_transition(&battle.mode, Battle_Mode.MOVE_TARGET) }
        }

        { // update
          entering, running, exiting := mode_update(&battle.mode)
          switch battle.mode.current {
            case .INIT: {
              if entering {
                log.debugf("[INIT] entered")
                battle.marker_position = {}
                battle.marker_visible = false
              }
              if running {
                ImGui.Text("Initializing battle...")
                // Wait for 1 second before changing state, we'll initialize other stuff here later.
                if time.diff(battle.mode.entered_at, time.now()) > 1 * time.Second {
                  mode_transition(&battle.mode, Battle_Mode.MOVE_TARGET)
                }
              }
            }
            case .MOVE_TARGET: {
              if entering {
                log.debugf("[MOVE_TARGET] entered")
                battle.marker_visible = true
                {
                  for &node, node_index in battle.board.nodes {
                    node.grid_index = u32(node_index)
                  }

                  start_position := grid_position_to_index(battle.marker_position, LEVEL_SIZE.x)
                  start_node := &battle.board.nodes[start_position]
                  expand_search :: proc(from, to: ^Node) -> bool {
                    return (from.distance + 1) <= 3;
                  }
                  clear(&battle.selected_tiles)
                  board_search(start_node, &battle.board, &battle.selected_tiles, expand_search)
                }
              }
              if running {
                if game.move_repeater.value != {} {
                  battle.marker_position = level_clamp_position_to_bounds(battle.marker_position + game.move_repeater.value, LEVEL_SIZE.xy)
                  mode_transition(&battle.mode, Battle_Mode.MOVE_TARGET)
                }
              }
            }
          }
        }

        { // draw
          rl.BeginMode3D(game.camera)
          defer rl.EndMode3D()

          push_level_matrix(LEVEL_SIZE.xy)
          defer rlgl.PopMatrix()

          draw_level_grid(LEVEL_SIZE.xy)
          draw_level_tiles(game.level_data);
          if battle.marker_visible {
            draw_level_marker(game.level_data, game.battle.marker_position);
          }
          draw_level_selected_tiles(game.level_data, game.battle.selected_tiles[:]);
        }
      }
      case .LEVEL_EDITOR: {
        level_editor := &game.level_editor

        input_raise, input_lower, input_grow, input_shrink, input_reset, input_save, input_load, input_rotate: bool
        input_move: Vector2i32
        { // keyboard inputs
          input_repeater_update_keyboard(&game.move_repeater, .LEFT, .RIGHT, .UP, .DOWN)

          if rl.IsKeyPressed(.SPACE) {
            if rl.IsKeyDown(.LEFT_SHIFT) { input_shrink = true }
            else                         { input_grow = true }
          }
          if rl.IsKeyPressed(.ENTER) {
            if rl.IsKeyDown(.LEFT_SHIFT) { input_lower = true }
            else                         { input_raise = true }
          }
          if rl.IsKeyPressed(.R) { input_reset = true }
          if rl.IsKeyPressed(.S) && rl.IsKeyDown(.LEFT_CONTROL) { input_save = true }
          if rl.IsKeyDown(.L) { input_rotate = true }
        }

        ImGui.SetNextWindowSize({ 350, 700 }, .Once)
        if ImGui.Begin("Level editor") {
          defer ImGui.End()

          ImGui.Text("- move cursor:        UP/DOWN/LEFT/RIGHT")
          ImGui.Text("- grow/shrink cursor: SPACE / SHIFT+SPACE")
          ImGui.Text("- raise/lower ground: SPACE / SHIFT+ENTER")
          ImGui.Text("- reset level:        R")
          ImGui.Text("- save level:         CTRL + S")
          ImGui.Text("- rotate camera:      L")

          ImGui.SeparatorText("Camera")
          ImGui.InputFloat3("position###camera_position", &game.camera.position)
          ImGui.InputFloat3("target###camera_target", &game.camera.target)
          ImGui.InputFloat3("up###camera_up", &game.camera.up)
          ImGui.InputFloat("fovy###camera_fovy", &game.camera.fovy)

          ImGui.SeparatorText("World")
          ImGui.SliderFloat("scale###world_scale", &game.world_scale, 0.1, 5)
          ImGui.SliderFloat("rotation###world_rotation", &game.world_rotation, 0, 360)

          ImGui.SeparatorText("Marker")
          ImGui.InputInt2("position###marker_position", auto_cast &level_editor.marker_position)
          ImGui.InputInt2("size###marker_size",     auto_cast &level_editor.marker_size)
          ImGui.Dummy({ 30, -1 })
          ImGui.SameLine()
          if ImGui.Button(" up ") { input_move.y = -1 }
          if ImGui.Button("left") { input_move.x = -1 }
          ImGui.SameLine(80)
          if ImGui.Button("right") { input_move.x = +1 }
          ImGui.SameLine(200)
          if ImGui.Button("grow") { input_grow = true }
          ImGui.SameLine()
          if ImGui.Button("shrink") { input_shrink = true }
          ImGui.Dummy({ 30, -1 }); ImGui.SameLine()
          if ImGui.Button("down") { input_move.y = -1 }

          ImGui.SeparatorText("Height")
          if ImGui.Button("raise") { input_raise = true }
          ImGui.SameLine()
          if ImGui.Button("lower") { input_lower = true }
          ImGui.SeparatorText("Level")

          if ImGui.Button("clear") { input_reset = true }
          if ImGui.Button("save to disk") { input_save = true }
          ImGui.SameLine()
          if ImGui.Button("load from disk") { input_load = true }

          ImGui.Text(fmt.ctprintf("size: %v", LEVEL_SIZE))
          ImGui.Text(fmt.ctprintf("tiles: %v", len(game.level_data.tiles)))
          for tile, tile_index in game.level_data.tiles {
            ImGui.Text(fmt.ctprintf("- %v %v", grid_index_to_position(i32(tile_index), LEVEL_SIZE.xy), tile))
          }
        }

        { // update
          if game.move_repeater.value != {} {
            level_editor.marker_position = level_clamp_position_to_bounds(level_editor.marker_position + game.move_repeater.value, LEVEL_SIZE.xy)
          }
          if input_grow {
            level_editor.marker_size.x = min(level_editor.marker_size.x + 1, LEVEL_SIZE.x/2-1)
            level_editor.marker_size.y = min(level_editor.marker_size.y + 1, LEVEL_SIZE.y/2-1)
          }
          if input_shrink {
            level_editor.marker_size.x = max(level_editor.marker_size.x - 1, 0)
            level_editor.marker_size.y = max(level_editor.marker_size.y - 1, 0)
          }
          if input_raise {
            positions := level_positions_in_area(game.level_data, level_editor.marker_position, level_editor.marker_size)
            for position in positions {
              tile := &game.level_data.tiles[grid_position_to_index(position, LEVEL_SIZE.x)]
              tile.height = min(tile.height + 1, u16(LEVEL_SIZE.z-1))
              tile.type = .DIRT
            }
          }
          if input_lower {
            positions := level_positions_in_area(game.level_data, level_editor.marker_position, level_editor.marker_size)
            for position in positions {
              tile := &game.level_data.tiles[grid_position_to_index(position, LEVEL_SIZE.x)]
              tile.height = u16(max(i32(tile.height) - 1, 0))
              if tile.height == 0 {
                tile.type = .EMPTY
              }
            }
          }
          if input_reset {
            for &tile in game.level_data.tiles {
              tile = {}
            }
          }
          if input_save {
            level_write_to_disk(&game.level_data, LEVEL_NAME)
          }
          if input_load {
            level_read_from_disk(&game.level_data, LEVEL_NAME)
          }
          if input_rotate {
            game.world_rotation += rl.GetFrameTime() * 80
          }
        }

        { // draw
          rl.BeginMode3D(game.camera)
          defer rl.EndMode3D()

          push_level_matrix(LEVEL_SIZE.xy)
          defer rlgl.PopMatrix()

          draw_level_grid(LEVEL_SIZE.xy)
          draw_level_tiles(game.level_data);
          draw_level_marker(game.level_data, level_editor.marker_position, level_editor.marker_size)
        }
      }
    }

    rl.DrawFPS(rl.GetScreenWidth() - 100, 10)

    // ImGui.ShowDemoWindow(nil)

    imgui_rl.render()
    rl.EndDrawing()

    free_all(context.temp_allocator)
  }
}

assets_path :: proc() -> string {
  cwd, cwd_err := os2.get_working_directory(context.temp_allocator)
  return strings.join({ cwd, "assets" }, "/", context.temp_allocator)
}
load_texture_from_memory :: proc(data: string) -> rl.Texture2D {
  image := rl.LoadImageFromMemory(".png", raw_data(data), c.int(len(data)))
  return rl.LoadTextureFromImage(image)
}

LEVEL_SIZE :: Vector3i32{ 10, 10, 5 }
Level_Data :: struct {
  tiles:      [LEVEL_SIZE.x*LEVEL_SIZE.y]Tile,
}
Tile :: struct {
  type:       enum { EMPTY, DIRT },
  height:     u16,
}
level_read_from_disk :: proc(level_data: ^Level_Data, file_name: string) -> bool {
  full_path := strings.join({ assets_path(), file_name }, "/")
  json_data, read_err := os2.read_entire_file(full_path, context.temp_allocator)
  if read_err != nil {
    log.errorf("Couldn't read level from disk. Error: %v", read_err)
    return false
  }
  unmarshal_err := json.unmarshal(json_data, level_data)
  if unmarshal_err != nil {
    log.errorf("Couldn't unmarshal level. Error: %v", unmarshal_err)
    return false
  }
  log.debugf("Level read from disk: %v", full_path)
  return true
}
level_write_to_disk :: proc(level_data: ^Level_Data, file_name: string) -> bool {
  full_path := strings.join({ assets_path(), file_name }, "/")
  json_data, marshal_err := json.marshal(level_data^, { pretty = true })
  if marshal_err != nil {
    log.errorf("Couldn't marshal level. Error: %v", marshal_err)
    return false
  }
  write_err := os2.write_entire_file(full_path, json_data)
  if write_err != nil {
    log.errorf("Couldn't write level to disk. Error: %v", write_err)
    return false
  }
  log.debugf("Level written to disk: %v", full_path)
  return true
}
level_positions_in_area :: proc(level_data: Level_Data, position: Vector2i32, size: Vector2i32) -> [dynamic]Vector2i32 {
  positions: [dynamic]Vector2i32
  positions.allocator = context.temp_allocator
  for y in -size.y ..= size.y {
    for x in -size.x ..= size.x {
      grid_position := position + { x, y }
      if !is_in_bounds(grid_position, LEVEL_SIZE.xy) {
        continue;
      }
      append(&positions, grid_position)
    }
  }
  return positions
}
level_clamp_position_to_bounds :: proc(grid_position: Vector2i32, level_size: Vector2i32) -> Vector2i32 {
  clamped_position: Vector2i32
  clamped_position.x = clamp(grid_position.x, 0, level_size.x - 1)
  clamped_position.y = clamp(grid_position.y, 0, level_size.y - 1)
  return clamped_position
}

is_in_bounds :: proc(position: Vector2i32, grid_size: Vector2i32) -> bool {
  return position.x >= 0 && position.y >= 0 && position.x < grid_size.x && position.y < grid_size.y
}
grid_position_to_index :: proc(position: Vector2i32, grid_width: i32) -> u32 {
  return u32((position.y * grid_width) + position.x);
}
grid_index_to_position :: proc(grid_index: i32, grid_size: Vector2i32) -> Vector2i32 {
  return { grid_index % grid_size.x, grid_index / grid_size.x };
}

draw_cube_texture :: proc(texture: rl.Texture2D, position: Vector3f32, size: Vector3f32, color: rl.Color) {
  x := position.x
  y := position.y
  z := position.z

  // Set desired texture to be enabled while drawing following vertex data
  rlgl.SetTexture(texture.id)

  rlgl.Begin(rlgl.QUADS)
    rlgl.Color4ub(color.r, color.g, color.b, color.a)
    // Front Face
    rlgl.Normal3f(0.0, 0.0, 1.0)       // Normal Pointing Towards Viewer
    rlgl.TexCoord2f(0.0, 0.0); rlgl.Vertex3f(x - size.x*0.5, y - size.y*0.5, z + size.z*0.5)  // Bottom Left Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 0.0); rlgl.Vertex3f(x + size.x*0.5, y - size.y*0.5, z + size.z*0.5)  // Bottom Right Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 1.0); rlgl.Vertex3f(x + size.x*0.5, y + size.y*0.5, z + size.z*0.5)  // Top Right Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 1.0); rlgl.Vertex3f(x - size.x*0.5, y + size.y*0.5, z + size.z*0.5)  // Top Left Of The Texture and Quad
    // Back Face
    rlgl.Normal3f(0.0, 0.0, - 1.0)     // Normal Pointing Away From Viewer
    rlgl.TexCoord2f(1.0, 0.0); rlgl.Vertex3f(x - size.x*0.5, y - size.y*0.5, z - size.z*0.5)  // Bottom Right Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 1.0); rlgl.Vertex3f(x - size.x*0.5, y + size.y*0.5, z - size.z*0.5)  // Top Right Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 1.0); rlgl.Vertex3f(x + size.x*0.5, y + size.y*0.5, z - size.z*0.5)  // Top Left Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 0.0); rlgl.Vertex3f(x + size.x*0.5, y - size.y*0.5, z - size.z*0.5)  // Bottom Left Of The Texture and Quad
    // Top Face
    rlgl.Normal3f(0.0, 1.0, 0.0)       // Normal Pointing Up
    rlgl.TexCoord2f(0.0, 1.0); rlgl.Vertex3f(x - size.x*0.5, y + size.y*0.5, z - size.z*0.5)  // Top Left Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 0.0); rlgl.Vertex3f(x - size.x*0.5, y + size.y*0.5, z + size.z*0.5)  // Bottom Left Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 0.0); rlgl.Vertex3f(x + size.x*0.5, y + size.y*0.5, z + size.z*0.5)  // Bottom Right Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 1.0); rlgl.Vertex3f(x + size.x*0.5, y + size.y*0.5, z - size.z*0.5)  // Top Right Of The Texture and Quad
    // Bottom Face
    rlgl.Normal3f(0.0, - 1.0, 0.0)     // Normal Pointing Down
    rlgl.TexCoord2f(1.0, 1.0); rlgl.Vertex3f(x - size.x*0.5, y - size.y*0.5, z - size.z*0.5)  // Top Right Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 1.0); rlgl.Vertex3f(x + size.x*0.5, y - size.y*0.5, z - size.z*0.5)  // Top Left Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 0.0); rlgl.Vertex3f(x + size.x*0.5, y - size.y*0.5, z + size.z*0.5)  // Bottom Left Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 0.0); rlgl.Vertex3f(x - size.x*0.5, y - size.y*0.5, z + size.z*0.5)  // Bottom Right Of The Texture and Quad
    // Right face
    rlgl.Normal3f(1.0, 0.0, 0.0)       // Normal Pointing Right
    rlgl.TexCoord2f(1.0, 0.0); rlgl.Vertex3f(x + size.x*0.5, y - size.y*0.5, z - size.z*0.5)  // Bottom Right Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 1.0); rlgl.Vertex3f(x + size.x*0.5, y + size.y*0.5, z - size.z*0.5)  // Top Right Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 1.0); rlgl.Vertex3f(x + size.x*0.5, y + size.y*0.5, z + size.z*0.5)  // Top Left Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 0.0); rlgl.Vertex3f(x + size.x*0.5, y - size.y*0.5, z + size.z*0.5)  // Bottom Left Of The Texture and Quad
    // Left Face
    rlgl.Normal3f( - 1.0, 0.0, 0.0)    // Normal Pointing Left
    rlgl.TexCoord2f(0.0, 0.0); rlgl.Vertex3f(x - size.x*0.5, y - size.y*0.5, z - size.z*0.5)  // Bottom Left Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 0.0); rlgl.Vertex3f(x - size.x*0.5, y - size.y*0.5, z + size.z*0.5)  // Bottom Right Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 1.0); rlgl.Vertex3f(x - size.x*0.5, y + size.y*0.5, z + size.z*0.5)  // Top Right Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 1.0); rlgl.Vertex3f(x - size.x*0.5, y + size.y*0.5, z - size.z*0.5)  // Top Left Of The Texture and Quad
  rlgl.End()

  rlgl.SetTexture(0)
}
push_level_matrix :: proc(level_size: Vector2i32) {
  translation := Vector2f32{ f32(level_size.x)*0.5, f32(level_size.y)*0.5 }
  rlgl.PushMatrix()
  rlgl.Translatef(translation.x, 0, translation.y)
  rlgl.Rotatef(game.world_rotation, 0, 1, 0)
  rlgl.Translatef(-translation.x, 0, -translation.y)
}
draw_level_grid :: proc(level_size: Vector2i32) {
  for x in 0 ..= level_size.x {
    start := Vector3f32{ f32(x), 0, 0 }
    end   := Vector3f32{ f32(x), 0, f32(level_size.y) }
    rl.DrawLine3D(start, end, rl.GRAY)
  }
  for y in 0 ..= level_size.y {
    start := Vector3f32{ 0, 0, f32(y) }
    end   := Vector3f32{ f32(level_size.x), 0, f32(y) }
    rl.DrawLine3D(start, end, rl.GRAY)
  }
}
draw_level_tiles :: proc(level_data: Level_Data) {
  for tile, tile_index in level_data.tiles {
    if tile.type == .EMPTY { continue }

    grid_position := grid_index_to_position(i32(tile_index), LEVEL_SIZE.xy)
    size := Vector3f32{ 1, f32(tile.height) * TILE_STEP_HEIGHT, 1 }
    position := Vector3f32{ f32(grid_position.x), size.y * 0.5, f32(grid_position.y) }
    draw_cube_texture(game.texture_dirt, position + TILE_OFFSET, size, rl.WHITE)
  }
}
draw_level_marker :: proc(level_data: Level_Data, marker_position: Vector2i32, marker_size: Vector2i32 = {}) {
  for grid_position in level_positions_in_area(level_data, marker_position, marker_size) {
    grid_index := grid_position_to_index(grid_position, LEVEL_SIZE.x)
    tile := level_data.tiles[grid_index]
    height := f32(tile.height) * TILE_STEP_HEIGHT + 0.02
    position := Vector3f32{ f32(grid_position.x), height, f32(grid_position.y) }
    size := Vector3f32{ 1, 0.1, 1 }
    draw_cube_texture(game.texture_dirt, position + TILE_OFFSET, size, rl.RED)
  }
}
draw_level_selected_tiles :: proc(level_data: Level_Data, selected_tiles: []Vector2i32) {
  for grid_position in selected_tiles {
    grid_index := grid_position_to_index(grid_position, LEVEL_SIZE.x)
    tile := level_data.tiles[grid_index]
    height := f32(tile.height) * TILE_STEP_HEIGHT + 0.01
    position := Vector3f32{ f32(grid_position.x), height, f32(grid_position.y) }
    size := Vector3f32{ 1, 0.1, 1 }
    draw_cube_texture(game.texture_dirt, position + TILE_OFFSET, size, rl.BLUE)
  }
}

Input_Repeater :: struct {
  value:          Vector2i32,
  threshold:      time.Duration,
  rate:           time.Duration,
  next:           time.Time,
  multiple_axis:  bool,
  hold:           bool,
}
input_repeater_update_keyboard :: proc(repeater: ^Input_Repeater, key_left, key_right, key_up, key_down: rl.KeyboardKey) {
  value: Vector2f32
  if      rl.IsKeyDown(key_left)  { value.x += 1 }
  else if rl.IsKeyDown(key_right) { value.x -= 1 }
  if      rl.IsKeyDown(key_up)    { value.y += 1 }
  else if rl.IsKeyDown(key_down)  { value.y -= 1 }
  if value != {} {
    value = glsl.normalize_vec2(value)
  }
  repeater_update(repeater, value)
}
repeater_update :: proc(repeater: ^Input_Repeater, raw_value: Vector2f32) {
  value: Vector2i32
  value.x = i32(math.round(raw_value.x))
  value.y = i32(math.round(raw_value.y))
  repeater.value = { 0, 0 }

  if value != {} {
    if repeater.multiple_axis == false {
      if math.abs(value.x) > math.abs(value.y) {
        value.y = 0
      } else {
        value.x = 0
      }
    }

    now := time.now()
    if time.diff(repeater.next, now) >= 0 {
      offset := repeater.hold ? repeater.rate : repeater.threshold
      repeater.hold = true
      repeater.next = time.time_add(now, offset)
      repeater.value = value
    }
  } else {
    repeater.hold = false
    repeater.next = {}
  }
}

Mode :: struct($M: typeid) {
  current:         M,
  entered_at:      time.Time,
}
mode_transition :: proc(mode: ^Mode($T), next: T) {
  mode.entered_at = {}
  mode.current    = next
}
mode_update :: proc(mode: ^Mode($T)) -> (entering, running, exiting: bool) {
  entering = mode.entered_at == {}
  if entering {
    mode.entered_at = time.now()
  }
  running = true
  exiting = false
  return entering, running, exiting
}

DIRECTION_VECTORS :: [Direction]Vector2i32{
  .NORTH = { 0, +1 },
  .EAST = { 0, -1 },
  .SOUTH = { +1, 0 },
  .WEST = { -1, 0 },
}
Direction :: enum { NORTH, EAST, SOUTH, WEST }
vector_to_direction :: proc(vector: Vector2i32) -> Direction {
  if vector.y > 0 { return .NORTH }
  if vector.y < 0 { return .SOUTH }
  if vector.x < 0 { return .EAST }
  return .WEST;
}
direction_to_euler :: proc(direction: Direction) -> Vector3f32 {
  return { 0, f32(direction) * 90, 0 };
}

Unit :: struct {
  position:   Vector2i32,
  direction:  Direction,
}

Board :: struct {
  nodes: [LEVEL_SIZE.x*LEVEL_SIZE.y]Node,
}
Node :: struct {
  grid_index: u32,
  previous:   i16,
  distance:   u16,
}
board_search :: proc(start_node: ^Node, board: ^Board, result: ^[dynamic]Vector2i32, add_node: proc(from: ^Node, to: ^Node) -> bool) {
  for &node in board.nodes {
    node.previous = -1
    node.distance = max(u16)
  }

  check_next: queue.Queue(^Node)
  queue.init(&check_next, allocator = context.temp_allocator)
  check_now: queue.Queue(^Node)
  queue.init(&check_now, allocator = context.temp_allocator)

  start_node.distance = 0
  queue.push_back(&check_now, start_node)
  for queue.len(check_now) > 0 {
    node := queue.dequeue(&check_now)
    node_position := grid_index_to_position(i32(node.grid_index), LEVEL_SIZE.xy)

    for direction in DIRECTION_VECTORS {
      next_position := node_position + direction
      next_node: ^Node
      if is_in_bounds(next_position, LEVEL_SIZE.xy) {
        next_grid_index := grid_position_to_index(next_position, LEVEL_SIZE.x)
        next_node = &board.nodes[next_grid_index]
      }

      if next_node == nil || next_node.distance < node.distance + 1 {
        continue
      }

      if add_node(node, next_node) {
        next_node.distance = node.distance + 1
        next_node.previous = i16(node.grid_index)
        queue.push_back(&check_next, next_node)
        append(result, next_position)
      }
    }

    if queue.len(check_now) == 0 {
      temp := check_now
      check_now = check_next
      check_next = temp
    }
  }
}
