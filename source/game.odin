package game

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg/glsl"
import "core:os/os2"
import "core:strings"
import "core:time"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import ImGui "../vendor/odin-imgui"
import imgui_rl "../vendor/imgui_impl_raylib"

Vector2f32 :: [2]f32
Vector3f32 :: [3]f32
Vector2i32 :: [2]i32
Vector3i32 :: [3]i32
Game_Mode :: enum { LEVEL_EDITOR }
Tile :: struct {
  position:   Vector2i32,
  height:     i32,
}
Level_Data :: struct {
  tiles:      map[u32]Tile,
  size:       Vector3i32,
}

EMBED_ASSETS :: #config(EMBED_ASSETS, false)
COLOR_CLEAR :: rl.Color{ 0, 0, 0, 255 }
TILE_STEP_HEIGHT :: 0.25

game_mode: Game_Mode
texture_dirt: rl.Texture
level_data: ^Level_Data
level_name : string = "level0.json"
camera: rl.Camera3D
marker_position: Vector2i32
marker_size: Vector2i32
world_scale: f32 = 1
world_rotation: f32
move_repeater: Input_Repeater = { threshold = 200 * time.Millisecond, rate = 100 * time.Millisecond }

main :: proc() {
  context.logger = log.create_console_logger()

  rl.SetConfigFlags({ .WINDOW_RESIZABLE, .VSYNC_HINT })
  rl.InitWindow(1920, 1080, "Tactics RPG (Odin + Raylib)")
  rl.SetTargetFPS(60)

  imgui_rl.init()

  camera.position   = { 0, 4, 0 }
  camera.target     = { 0, 0, 0 }
  camera.up         = { 0, 1, 0 }
  camera.fovy       = 14
  camera.projection = .ORTHOGRAPHIC

  load_texture_from_memory :: proc(data: string) -> rl.Texture2D {
    image := rl.LoadImageFromMemory(".png", raw_data(data), c.int(len(data)))
    return rl.LoadTextureFromImage(image)
  }

  when EMBED_ASSETS {
    texture_dirt = load_texture_from_memory(#load("../assets/Dirt.png"))
  } else {
    texture_dirt = rl.LoadTexture("assets/Dirt.png")
  }

  for !rl.WindowShouldClose() {
    imgui_rl.new_frame()

    rl.BeginDrawing()
    rl.ClearBackground(COLOR_CLEAR)

    switch game_mode {
      case .LEVEL_EDITOR: {
        if level_data == nil {
          level_data = new(Level_Data)
          level_data.size = { 10, 10, 5 }
          level_read_from_disk(level_data, level_name)

          camera.target = { f32(level_data.size.x/2), 0, f32(level_data.size.y/2) }
        }

        input_raise, input_lower, input_grow, input_shrink, input_reset, input_save, input_load, input_rotate: bool
        input_move: Vector2i32
        { // keyboard inputs
          move: Vector2f32
          if      rl.IsKeyDown(.LEFT)  { move.x -= 1 }
          else if rl.IsKeyDown(.RIGHT) { move.x += 1 }
          if      rl.IsKeyDown(.UP)    { move.y -= 1 }
          else if rl.IsKeyDown(.DOWN)  { move.y += 1 }
          if move != {} {
            move = glsl.normalize_vec2(move)
          }
          repeater_update(&move_repeater, move)

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

          ImGui.SeparatorText("Inputs")
          ImGui.Text("- move cursor:        UP/DOWN/LEFT/RIGHT")
          ImGui.Text("- grow/shrink cursor: SPACE / SHIFT+SPACE")
          ImGui.Text("- raise/lower ground: SPACE / SHIFT+ENTER")
          ImGui.Text("- reset level:        R")
          ImGui.Text("- save level:         CTRL + S")
          ImGui.Text("- rotate camera:      L")

          ImGui.SeparatorText("Camera")
          ImGui.InputFloat3("position###camera_position", &camera.position)
          ImGui.InputFloat3("target###camera_target", &camera.target)
          ImGui.InputFloat3("up###camera_up", &camera.up)
          ImGui.InputFloat("fovy###camera_fovy", &camera.fovy)

          ImGui.SeparatorText("World")
          ImGui.SliderFloat("scale###world_scale", &world_scale, 0.1, 5)
          ImGui.SliderFloat("rotation###world_rotation", &world_rotation, 0, 360)

          ImGui.SeparatorText("Marker")
          ImGui.InputInt2("position###marker_position", auto_cast &marker_position)
          ImGui.InputInt2("size###marker_size",     auto_cast &marker_size)
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
          ImGui.SameLine()
          if ImGui.Button("save") { input_save = true }
          ImGui.SameLine()
          if ImGui.Button("load") { input_load = true }

          ImGui.Text(fmt.ctprintf("size: %v", level_data.size))
          ImGui.Text(fmt.ctprintf("tiles: %v", len(level_data.tiles)))
          for position, tile in level_data.tiles {
            ImGui.Text(fmt.ctprintf("- %v", tile))
          }
        }

        { // react to inputs
          if move_repeater.value.y < 0 {
            marker_position.y = clamp(marker_position.y + 1, 0, level_data.size.y - 1)
          } else if move_repeater.value.y > 0 {
            marker_position.y = clamp(marker_position.y - 1, 0, level_data.size.y - 1)
          }
          if move_repeater.value.x < 0 {
            marker_position.x = clamp(marker_position.x + 1, 0, level_data.size.x - 1)
          } else if move_repeater.value.x > 0 {
            marker_position.x = clamp(marker_position.x - 1, 0, level_data.size.x - 1)
          }
          if input_grow {
            marker_size.x = min(marker_size.x + 1, level_data.size.x/2-1)
            marker_size.y = min(marker_size.y + 1, level_data.size.y/2-1)
          }
          if input_shrink {
            marker_size.x = max(marker_size.x - 1, 0)
            marker_size.y = max(marker_size.y - 1, 0)
          }
          if input_raise {
            positions := level_positions_in_area(level_data, marker_position, marker_size)
            for position in positions {
              tile := level_get_or_create_tile(level_data, position)
              tile.height = min(tile.height + 1, level_data.size.z-1)
            }
          }
          if input_lower {
            positions := level_positions_in_area(level_data, marker_position, marker_size)
            for position in positions {
              tile := level_get_or_create_tile(level_data, position)
              tile.height = max(tile.height - 1, 0)
            }
          }
          if input_reset {
            clear(&level_data.tiles)
          }
          if input_save {
            level_write_to_disk(level_data, level_name)
          }
          if input_load {
            level_read_from_disk(level_data, level_name)
          }
          if input_rotate {
            world_rotation += rl.GetFrameTime() * 80
          }
        }

        {
          rl.BeginMode3D(camera)

          t := Vector2f32{ f32(level_data.size.x)/2, f32(level_data.size.y)/2 }

          rlgl.PushMatrix()
          rlgl.Translatef(t.x, 0, t.x)
          rlgl.Scalef(world_scale, world_scale, world_scale)
          rlgl.Rotatef(world_rotation, 0, 1, 0)
          rlgl.Translatef(-t.x, 0, -t.y)

          { // draw grid
            for x in 0 ..= level_data.size.x {
              origin := Vector3f32{ f32(x), 0, 0 }
              rl.DrawLine3D(origin, origin + { 0, 0, f32(level_data.size.y) }, rl.GRAY)
            }
            for y in 0 ..= level_data.size.y {
              origin := Vector3f32{ 0, 0, f32(y) }
              rl.DrawLine3D(origin, origin + { f32(level_data.size.x), 0, 0 }, rl.GRAY)
            }
          }

          tile_offset  := Vector3f32{ 0.5, 0, 0.5 }

          for _, tile in level_data.tiles {
            position: Vector3f32
            position.x = f32(tile.position.x)
            position.y = f32(tile.height) * 0.5
            position.z = f32(tile.position.y)
            size := Vector3f32{ 1, f32(tile.height), 1 }
            draw_cube_texture(texture_dirt, position + tile_offset, size, rl.WHITE)
          }

          for pos in level_positions_in_area(level_data, marker_position, marker_size) {
            grid_index := position_to_grid_index(pos, level_data.size.x)
            tile, tile_found := level_data.tiles[grid_index]
            height: f32 = 0.02
            if tile_found {
              height += f32(tile.height)
            }
            position := Vector3f32{ f32(pos.x), height, f32(pos.y) }
            size     := Vector3f32{ 1, 0.1, 1 }
            draw_cube_texture(texture_dirt, position + tile_offset, size, rl.RED)
          }

          rlgl.PopMatrix()

          rl.EndMode3D()
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
level_get_or_create_tile :: proc(level: ^Level_Data, position: Vector2i32) -> ^Tile {
  grid_index := position_to_grid_index(position, level_data.size.x)
  tile, ok := &level.tiles[grid_index]
  if !ok {
    level.tiles[grid_index] = Tile{}
    tile = &level.tiles[grid_index]
    tile.position = position
  }
  return tile
}
level_positions_in_area :: proc(level_data: ^Level_Data, position: Vector2i32, size: Vector2i32) -> [dynamic]Vector2i32 {
  positions: [dynamic]Vector2i32
  positions.allocator = context.temp_allocator
  for y in -marker_size.y ..= marker_size.y {
    for x in -marker_size.x ..= marker_size.x {
      position := marker_position + { x, y }
      if !is_in_bounds(position, level_data.size.xy) {
        continue;
      }
      append(&positions, position)
    }
  }
  return positions
}

is_in_bounds :: proc(position: Vector2i32, grid_size: Vector2i32) -> bool {
  return position.x >= 0 && position.y >= 0 && position.x < grid_size.x && position.y < grid_size.y
}
position_to_grid_index :: proc(position: Vector2i32, grid_width: i32) -> u32 {
  return u32((position.y * grid_width) + position.x);
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

Input_Repeater :: struct {
  value:          Vector2i32,
  threshold:      time.Duration,
  rate:           time.Duration,
  next:           time.Time,
  multiple_axis:  bool,
  hold:           bool,
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
