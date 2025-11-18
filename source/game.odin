package game

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:container/queue"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/ease"
import "core:math/linalg"
import "core:math/linalg/glsl"
import "core:mem"
import "core:mem/virtual"
import "core:os/os2"
import "core:slice"
import "core:sort"
import "core:strings"
import "core:time"
import "core:testing"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import ImGui "../vendor/odin-imgui"
import imgui_rl "../vendor/imgui_impl_raylib"

EMBED_ASSETS :: #config(EMBED_ASSETS, false)
COLOR_CLEAR :: rl.Color{ 0, 0, 0, 255 }
TILE_STEP_HEIGHT :: 0.25
TILE_OFFSET :: Vector3f32{ 0.5, 0, 0.5 }
LEVEL_NAME :: "level0.json"
MENU_NINE_PATCH_INFOS :: rl.NPatchInfo{ { 0, 0, 48, 77 }, 41, 47, 9, 36, .NINE_PATCH }
COLOR_MENU_HEADER_TEXT :: rl.Color{ 0x26, 0xA4, 0xB1, 0xFF }
COLOR_MENU_ITEM_TEXT :: rl.Color{ 0xFF, 0xFF, 0xFF, 0xFF }
COLOR_MENU_ITEM_TEXT_SELECTED :: rl.Color{ 0xF9, 0xD2, 0x76, 0xFF }
COLOR_MENU_ITEM_TEXT_LOCKED :: rl.Color{ 0x80, 0x80, 0x80, 0xFF }
MENU_ITEM_HEIGHT :: 35
MENU_BASE_SIZE :: Vector2f32{ 180, 65 }

g: Game_State

Game_State :: struct {
  game_mode:            Mode(Game_Mode),
  mode_arena:           Static_Arena(8*mem.Kilobyte),
  camera:               rl.Camera3D,
  level_data:           Level_Data,
  world_scale:          f32,
  world_rotation:       f32,
  level_editor:         Level_Editor,
  battle:               Battle,
  battle_mode:          Mode(Battle_Mode),
  battle_mode_arena:    Static_Arena(8*mem.Kilobyte),
  turn_arena:           Static_Arena(64*mem.Kilobyte),
  move_arena:           Static_Arena(64*mem.Kilobyte),
  ui_scale:             f32,
  debug_window_game:    bool,
  window_size:          Vector2i32,
  inputs:               struct {
    move:                 Input_Repeater,
    confirm:              bool,
    cancel:               bool,
  },
  // assets
  texture_dirt:                 rl.Texture,
  texture_menu:                 rl.Texture,
  texture_menu_bullet:          rl.Texture,
  texture_menu_bullet_locked:   rl.Texture,
  texture_menu_bullet_selected: rl.Texture,
  font_arial:                   rl.Font,
}
Vector2f32 :: [2]f32
Vector3f32 :: [3]f32
Vector4f32 :: [4]f32
Vector2i32 :: [2]i32
Vector3i32 :: [3]i32
Vector4i32 :: [4]i32
Game_Mode :: enum u8 { TITLE, BATTLE, LEVEL_EDITOR }
Level_Editor :: struct {
  level_name:       string,
  marker_position:  Vector2i32,
  marker_size:      Vector2i32,
}
Battle :: struct {
  marker_position:        Vector2i32,
  marker_visible:         bool,
  board:                  Board,
  turn_actor:             int,
  turn:                   struct {
    start_position:         Vector2i32,
    start_direction:        Direction,
    moved:                  bool,
    acted:                  bool,
    move_locked:            bool,
    category_selected:      int,
  },
  selected_tiles:         [dynamic]Vector2i32,
  move_sequence:          Move_Sequence,
  menu_title:             string,
  menu_items:             [dynamic]Menu_Item,
  menu_selected:          int,
  menu_size:              Vector2f32,
  menu_position:          Vector2f32,
  menu_flux_map:          ease.Flux_Map(f32),
}

Move_Sequence :: struct {
  steps:                  [dynamic]Move_Step,
  current:                int,
  current_started_at:     time.Time,
}
Move_Step :: struct {
  name:           string,
  direction_from: Direction,
  direction_to:   Direction,
  from:           Vector2i32,
  to:             Vector2i32,
  flux_map:       ease.Flux_Map(f32),
}
Battle_Mode :: enum u8 { INIT, SELECT_UNIT, SELECT_COMMAND, SELECT_CATEGORY, SELECT_ACTION, MOVE_TARGET, MOVE_SEQUENCE, EXPLORE }

main :: proc() {
  when ODIN_DEBUG { // Quick debug code to check for memory leaks when we close the game
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    defer {
      if len(track.allocation_map) > 0 {
        fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
        for _, entry in track.allocation_map {
          fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
        }
      }
      mem.tracking_allocator_destroy(&track)
    }
  }

  context.logger = log.create_console_logger()
  defer log.destroy_console_logger(context.logger)

  rl.SetConfigFlags({ .WINDOW_RESIZABLE, .VSYNC_HINT })
  rl.InitWindow(1920, 1080, "Tactics RPG (Odin + Raylib)")
  rl.SetTargetFPS(60)
  rl.SetExitKey(.KEY_NULL)

  imgui_rl.init()

  static_arena_init(&g.mode_arena, "game_mode_arena")
  static_arena_init(&g.battle_mode_arena, "battle_mode_arena")
  static_arena_init(&g.turn_arena, "turn_arena")
  static_arena_init(&g.move_arena, "move_arena")

  g.game_mode.arena = &g.mode_arena.arena
  g.world_scale = 1
  g.ui_scale = 2
  level_read_from_disk(&g.level_data, LEVEL_NAME)
  g.camera.position   = { 0, 4, 0 }
  g.camera.target     = { 0, 0, 0 }
  g.camera.up         = { 0, 1, 0 }
  g.camera.fovy       = 14
  g.camera.projection = .ORTHOGRAPHIC
  g.camera.target     = { f32(LEVEL_SIZE.x)*0.5, 0, f32(LEVEL_SIZE.y)*0.5 }
  g.inputs.move.threshold = 200 * time.Millisecond
  g.inputs.move.rate      = 100 * time.Millisecond
  g.debug_window_game = ODIN_DEBUG

  g.battle_mode.arena                    = &g.battle_mode_arena.arena
  g.battle.selected_tiles.allocator      = g.turn_arena.allocator
  g.battle.move_sequence.steps.allocator = g.move_arena.allocator
  g.battle.menu_flux_map = ease.flux_init(f32)
  defer ease.flux_destroy(g.battle.menu_flux_map)

  g.texture_dirt = load_texture_png("../assets/Dirt.png")
  g.texture_menu = load_texture_png("../assets/AbilityMenu.png")
  g.texture_menu_bullet = load_texture_png("../assets/MenuBullet.png")
  g.texture_menu_bullet_locked = load_texture_png("../assets/MenuBulletLocked.png")
  g.texture_menu_bullet_selected = load_texture_png("../assets/MenuBulletSelected.png")
  g.font_arial   = load_font_ttf("../assets/arial.ttf", 24)

  for !rl.WindowShouldClose() {
    imgui_rl.new_frame()

    rl.BeginDrawing()
    rl.ClearBackground(COLOR_CLEAR)

    { // update
      g.window_size.x = rl.GetScreenWidth()
      g.window_size.y = rl.GetScreenHeight()
      ease.flux_update(&g.battle.menu_flux_map, f64(rl.GetFrameTime()))

      input_repeater_update_keyboard(&g.inputs.move, .LEFT, .RIGHT, .UP, .DOWN)
      g.inputs.confirm = rl.IsKeyPressed(.ENTER)
      g.inputs.cancel  = rl.IsKeyPressed(.ESCAPE)
    }

    { // debug menu
      {
        if rl.IsKeyPressed(.F1) { mode_transition(&g.game_mode, Game_Mode.BATTLE) }
        if rl.IsKeyPressed(.F2) { mode_transition(&g.game_mode, Game_Mode.LEVEL_EDITOR) }
      }
      if ImGui.BeginMainMenuBar() {
        defer ImGui.EndMainMenuBar()
        if ImGui.BeginMenu("Window") {
          defer ImGui.EndMenu()
          if ImGui.MenuItem("Debug", "", g.debug_window_game) {
            g.debug_window_game = !g.debug_window_game
          }
          if ImGui.MenuItem("Battle", "F1", g.game_mode.current == .BATTLE) {
            mode_transition(&g.game_mode, Game_Mode.BATTLE)
          }
          if ImGui.MenuItem("Level editor", "F2", g.game_mode.current == .LEVEL_EDITOR) {
            mode_transition(&g.game_mode, Game_Mode.LEVEL_EDITOR)
          }
        }
      }

      if g.debug_window_game {
        if ImGui.Begin("Debug", &g.debug_window_game) {
          ImGui.SeparatorText("Arenas")
          static_arena_imgui_progress_bar(g.mode_arena)
          static_arena_imgui_progress_bar(g.battle_mode_arena)
          static_arena_imgui_progress_bar(g.turn_arena)
          static_arena_imgui_progress_bar(g.move_arena)
          ImGui.SliderFloat("ui_scale", &g.ui_scale, 0.5, 4)
          ImGui.Text(fmt.ctprintf("g.inputs.confirm: %v", g.inputs.confirm))
          ImGui.Text(fmt.ctprintf("g.inputs.cancel:  %v", g.inputs.cancel))
        }
        ImGui.End()
      }
    }

    mode_update(&g.game_mode)
    switch g.game_mode.current {
      case .TITLE: {
        ImGui.Text("- Start battle:      F1")
        ImGui.Text("- Open level editor: F2")
        mode_transition(&g.game_mode, Game_Mode.BATTLE)
      }
      case .BATTLE: {
        if g.game_mode.entering {
          g.battle.menu_size                     = MENU_BASE_SIZE
          g.battle.menu_position.x               = g.battle.menu_size.x
        }

        {
          ImGui.SetNextWindowSize({ 350, 700 }, .Once)
          if ImGui.Begin("Battle", nil, { .NoFocusOnAppearing }) {
            ImGui.Text(fmt.ctprintf("Current mode: %v", g.battle_mode.current))

            if ImGui.Button("Restart battle") {
              mode_transition(&g.battle_mode, Battle_Mode.INIT)
            }

            ImGui.Text(fmt.ctprintf("battle.turn:            %v", g.battle.turn))
            ImGui.Text(fmt.ctprintf("battle.marker_position: %v (height: %v, type: %v)", g.battle.marker_position, g.level_data.tiles[grid_position_to_index(g.battle.marker_position, LEVEL_SIZE.x)].height, g.level_data.tiles[grid_position_to_index(g.battle.marker_position, LEVEL_SIZE.x)].type))

            if ImGui.TreeNode("Units") {
              defer ImGui.TreePop()

              for &unit, unit_index in g.battle.board.units {
                ImGui.PushIDInt(i32(unit_index))
                defer ImGui.PopID()
                ImGui.Text(fmt.ctprintf("- %v %v", unit_index, unit))
                ImGui.SetNextItemWidth(50); ImGui.InputScalar("direction", .U8, auto_cast &unit.direction)
              }
            }
          }
          ImGui.End()

          actor := &g.battle.board.units[g.battle.turn_actor]

          { // battle update
            mode_update(&g.battle_mode)
            switch g.battle_mode.current {
              case .INIT: {
                if g.battle_mode.entering {
                  log.debugf("[INIT] entered")
                  g.battle.marker_position = {}
                  g.battle.marker_visible = false
                  g.battle.turn_actor = 0
                  g.battle.turn = {}
                  g.battle.board.units[0] = {} // Left empty on purpose
                  g.battle.board.units[1] = { type = 1, position = { 2, 3 }, movement = .WALK,     move = 15, jump = 2 }
                  g.battle.board.units[2] = { type = 1, position = { 1, 1 }, movement = .TELEPORT, move = 9, jump = 2 }
                  g.battle.board.units[3] = { type = 1, position = { 5, 5 }, movement = .FLY,      move = 4, jump = 2 }

                  for &unit in g.battle.board.units {
                    unit.transform.position = grid_to_world_position(unit.position)
                    unit.transform.scale    = { 1, 1, 1 }
                  }
                }
                {
                  // Wait for 1 second before changing state, we'll initialize other stuff here later.
                  /* if time.diff(g.battle_mode.entered_at, time.now()) > 1 * time.Second */ {
                    mode_transition(&g.battle_mode, Battle_Mode.SELECT_UNIT)
                  }
                }
              }
              case .SELECT_UNIT: {
                if g.battle_mode.entering {
                  // Start of a new turn, clear the arena
                  virtual.arena_free_all(&g.turn_arena.arena)

                  g.battle.turn = {}
                  g.battle.turn_actor += 1
                  if g.battle.turn_actor == 0 || g.battle.board.units[g.battle.turn_actor].type == 0 {
                    g.battle.turn_actor = 1
                  }

                  actor = &g.battle.board.units[g.battle.turn_actor]
                  g.battle.turn.start_direction = actor.direction
                  g.battle.turn.start_position  = actor.position

                  mode_transition(&g.battle_mode, Battle_Mode.SELECT_COMMAND)
                }
              }
              case .SELECT_COMMAND: {
                if g.battle_mode.entering {
                  g.battle.marker_visible = true

                  menu_open("Commands", []Menu_Item{
                    { text = "Move",    locked = g.battle.turn.moved },
                    { text = "Actions", locked = g.battle.turn.acted },
                    { text = "Wait" },
                  })
                }

                {
                  g.battle.marker_position = actor.position

                  confirm_pressed := menu_update()
                  if confirm_pressed {
                    if g.battle.menu_selected == 0 {
                      mode_transition(&g.battle_mode, Battle_Mode.MOVE_TARGET)
                    }
                    if g.battle.menu_selected == 1 {
                      mode_transition(&g.battle_mode, Battle_Mode.SELECT_CATEGORY)
                    }
                    if g.battle.menu_selected == 2 {
                      mode_transition(&g.battle_mode, Battle_Mode.SELECT_UNIT)
                    }
                  }

                  if g.inputs.cancel {
                    if g.battle.turn.moved && !g.battle.turn.move_locked {
                      g.battle.turn.moved = false
                      actor.direction          = g.battle.turn.start_direction
                      actor.position           = g.battle.turn.start_position
                      actor.transform.rotation = direction_to_rotation(actor.direction)
                      actor.transform.position = grid_to_world_position(actor.position)
                      g.battle.menu_items[0].locked = false
                    } else {
                      mode_transition(&g.battle_mode, Battle_Mode.EXPLORE)
                    }
                  }
                }

                if g.battle_mode.exiting {
                  menu_close()
                }
              }
              case .SELECT_CATEGORY: {
                if g.battle_mode.entering {
                  g.battle.marker_visible = true
                  g.battle.marker_position = actor.position

                  menu_open("Actions", []Menu_Item{
                    { text = "Attack",      locked = false },
                    { text = "White Magic", locked = false },
                    { text = "Black Magic", locked = false },
                  })
                }

                {
                  confirm_pressed := menu_update()
                  if confirm_pressed {
                    switch g.battle.menu_selected {
                      case 0: {
                        g.battle.turn.acted = true
                        if g.battle.turn.moved {
                          g.battle.turn.move_locked = true
                        }
                        mode_transition(&g.battle_mode, Battle_Mode.SELECT_COMMAND)
                      }
                      case: {
                        g.battle.turn.category_selected = g.battle.menu_selected
                        mode_transition(&g.battle_mode, Battle_Mode.SELECT_ACTION)
                      }
                    }
                  }

                  if g.inputs.cancel {
                    mode_transition(&g.battle_mode, Battle_Mode.SELECT_COMMAND)
                  }
                }

                if g.battle_mode.exiting {
                  menu_close()
                }
              }
              case .SELECT_ACTION: {
                if g.battle_mode.entering {
                  g.battle.marker_visible = true
                  g.battle.marker_position = actor.position

                  menu_category_items := [][]string{
                    {},
                    { "Cure", "Raise", "Holy" },
                    { "Fire", "Ice", "Lightning" },
                  }

                  menu_items: [dynamic]Menu_Item
                  menu_items.allocator = context.temp_allocator
                  for item in menu_category_items[g.battle.turn.category_selected] {
                    append(&menu_items, Menu_Item{ text = item })
                  }
                  menu_open("Actions", menu_items[:])
                }

                {
                  confirm_pressed := menu_update()
                  if confirm_pressed {
                    g.battle.turn.acted = true
                    if g.battle.turn.moved {
                      g.battle.turn.move_locked = true
                    }
                    mode_transition(&g.battle_mode, Battle_Mode.SELECT_COMMAND)
                  }

                  if g.inputs.cancel {
                    mode_transition(&g.battle_mode, Battle_Mode.SELECT_CATEGORY)
                  }
                }

                if g.battle_mode.exiting {
                  menu_close()
                }
              }
              case .MOVE_TARGET: {
                if g.battle_mode.entering {
                  virtual.arena_free_all(&g.move_arena.arena)
                  g.battle.marker_visible = true
                  g.battle.marker_position = actor.position
                  {
                    for &node, node_index in g.battle.board.nodes {
                      node.grid_index = u32(node_index)
                    }

                    start_position := grid_position_to_index(g.battle.marker_position, LEVEL_SIZE.x)
                    start_node := &g.battle.board.nodes[start_position]
                    expand_search :: proc(from, to: ^Node, unit: ^Unit) -> bool {
                      from_position := grid_index_to_position(i32(from.grid_index), LEVEL_SIZE.x)
                      from_tile     := g.level_data.tiles[from.grid_index]
                      to_position   := grid_index_to_position(i32(to.grid_index), LEVEL_SIZE.x)
                      to_tile       := g.level_data.tiles[to.grid_index]

                      switch unit.movement {
                        case .WALK: {
                          if abs(i32(from_tile.height) - i32(to_tile.height)) > i32(unit.jump) {
                            return false
                          }
                        }
                        case .FLY: {}
                        case .TELEPORT: {}
                      }
                      return (from.distance + 1) <= u16(unit.move);
                    }
                    search_result := board_search(start_node, &g.battle.board, auto_cast expand_search, actor)
                    clear(&g.battle.selected_tiles)
                    filter_occupied: for grid_position in search_result {
                      for unit in g.battle.board.units {
                        if unit.type == 0 { continue }
                        if unit.position == grid_position { continue filter_occupied }
                      }
                      append(&g.battle.selected_tiles, grid_position)
                    }
                  }
                }

                {
                  if g.inputs.move.value != {} {
                    g.battle.marker_position = level_clamp_position_to_bounds(g.battle.marker_position + g.inputs.move.value, LEVEL_SIZE.xy)
                  }

                  if g.inputs.confirm {
                    mode_transition(&g.battle_mode, Battle_Mode.MOVE_SEQUENCE)
                  }

                  if g.inputs.cancel {
                    mode_transition(&g.battle_mode, Battle_Mode.SELECT_COMMAND)
                  }
                }

                if g.battle_mode.exiting {
                  clear(&g.battle.selected_tiles)
                }
              }
              case .MOVE_SEQUENCE: {
                if g.battle_mode.entering {
                  g.battle.marker_visible = false
                  g.battle.turn.moved     = true
                  unit_move_sequence_prepare(actor, g.battle.marker_position, &g.battle.move_sequence, &g.battle.board, &g.level_data)
                }
                {
                  if unit_move_sequence_execute(actor, &g.battle.move_sequence) {
                    mode_transition(&g.battle_mode, Battle_Mode.SELECT_COMMAND)
                  }
                }
              }
              case .EXPLORE: {
                if g.battle_mode.entering {
                  g.battle.marker_visible = true
                  g.battle.marker_position = actor.position
                }

                {
                  if g.inputs.move.value != {} {
                    g.battle.marker_position = level_clamp_position_to_bounds(g.battle.marker_position + g.inputs.move.value, LEVEL_SIZE.xy)
                  }

                  if g.inputs.confirm {
                    mode_transition(&g.battle_mode, Battle_Mode.SELECT_COMMAND)
                  }
                  if g.inputs.cancel {
                    mode_transition(&g.battle_mode, Battle_Mode.SELECT_COMMAND)
                  }
                }

                if g.battle_mode.exiting {
                  clear(&g.battle.selected_tiles)
                }
              }
            }
          }

          { // battle draw
            rl.BeginMode3D(g.camera)
            defer rl.EndMode3D()

            push_level_matrix(LEVEL_SIZE.xy)
            defer rlgl.PopMatrix()

            draw_level_grid(LEVEL_SIZE.xy)
            draw_level_tiles(g.level_data);
            if g.battle.marker_visible {
              draw_level_marker(g.level_data, g.battle.marker_position);
            }
            draw_level_selected_tiles(g.level_data, g.battle.selected_tiles[:]);
            draw_level_units(g.level_data, g.battle.board.units[:]);
          }

          { // battle draw ui
            menu_size := Vector2f32{ g.battle.menu_size.x, g.battle.menu_size.y + f32(len(g.battle.menu_items)) * MENU_ITEM_HEIGHT }
            rlgl.PushMatrix()
            {
              rlgl.Translatef(f32(g.window_size.x), f32(g.window_size.y) - 160, 0)
              rlgl.Scalef(g.ui_scale, g.ui_scale, 0)

              rlgl.PushMatrix()
              {
                translate_x := g.battle.menu_position.x - menu_size.x
                translate_y := g.battle.menu_position.y - menu_size.y
                rlgl.Translatef(translate_x, translate_y, 0)

                rl.DrawTextureNPatch(
                  g.texture_menu, MENU_NINE_PATCH_INFOS,
                  { 0, 0, menu_size.x, menu_size.y },
                  { 0, 0 }, 0, rl.WHITE
                )

                position := Vector2f32{ 42, 14 }
                rl.DrawTextEx(g.font_arial, to_temp_cstring(g.battle.menu_title), position, 24, 0, COLOR_MENU_HEADER_TEXT)
                position.y += 40
                for menu_item, menu_item_index in g.battle.menu_items {
                  color := COLOR_MENU_ITEM_TEXT
                  bullet_texture := g.texture_menu_bullet
                  if menu_item_index == g.battle.menu_selected {
                    color = COLOR_MENU_ITEM_TEXT_SELECTED
                    bullet_texture = g.texture_menu_bullet_selected
                  }
                  if menu_item.locked {
                    color = COLOR_MENU_ITEM_TEXT_LOCKED
                    bullet_texture = g.texture_menu_bullet_locked
                  }
                  rl.DrawTextEx(g.font_arial, to_temp_cstring(menu_item.text), position, 24, 0, color)
                  rl.DrawTexture(bullet_texture, i32(position.x) - 27, i32(position.y) + 2, rl.WHITE)

                  position.y += MENU_ITEM_HEIGHT
                }
              }
              rlgl.PopMatrix()
            }
            rlgl.PopMatrix()
          }
        }

        if g.game_mode.exiting {

        }
      }
      case .LEVEL_EDITOR: {
        level_editor := &g.level_editor

        input_raise, input_lower, input_grow, input_shrink, input_reset, input_save, input_load, input_rotate: bool
        input_move: Vector2i32
        { // keyboard inputs
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
        if ImGui.Begin("Level editor", nil, { .NoFocusOnAppearing }) {
          ImGui.Text("- move cursor:        UP/DOWN/LEFT/RIGHT")
          ImGui.Text("- grow/shrink cursor: SPACE / SHIFT+SPACE")
          ImGui.Text("- raise/lower ground: SPACE / SHIFT+ENTER")
          ImGui.Text("- reset level:        R")
          ImGui.Text("- save level:         CTRL + S")
          ImGui.Text("- rotate camera:      L")

          ImGui.SeparatorText("Camera")
          ImGui.InputFloat3("position###camera_position", &g.camera.position)
          ImGui.InputFloat3("target###camera_target", &g.camera.target)
          ImGui.InputFloat3("up###camera_up", &g.camera.up)
          ImGui.InputFloat("fovy###camera_fovy", &g.camera.fovy)

          ImGui.SeparatorText("World")
          ImGui.SliderFloat("scale###world_scale", &g.world_scale, 0.1, 5)
          ImGui.SliderFloat("rotation###world_rotation", &g.world_rotation, 0, 360)

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
          ImGui.Text(fmt.ctprintf("tiles: %v", len(g.level_data.tiles)))
          for tile, tile_index in g.level_data.tiles {
            ImGui.Text(fmt.ctprintf("- %v %v", grid_index_to_position(i32(tile_index), LEVEL_SIZE.xy), tile))
          }
        }
        ImGui.End()

        { // update
          if g.inputs.move.value != {} {
            level_editor.marker_position = level_clamp_position_to_bounds(level_editor.marker_position + g.inputs.move.value, LEVEL_SIZE.xy)
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
            positions := level_positions_in_area(g.level_data, level_editor.marker_position, level_editor.marker_size)
            for position in positions {
              tile := &g.level_data.tiles[grid_position_to_index(position, LEVEL_SIZE.x)]
              tile.height = min(tile.height + 1, u16(LEVEL_SIZE.z-1))
              tile.type = .DIRT
            }
          }
          if input_lower {
            positions := level_positions_in_area(g.level_data, level_editor.marker_position, level_editor.marker_size)
            for position in positions {
              tile := &g.level_data.tiles[grid_position_to_index(position, LEVEL_SIZE.x)]
              tile.height = u16(max(i32(tile.height) - 1, 0))
              if tile.height == 0 {
                tile.type = .EMPTY
              }
            }
          }
          if input_reset {
            for &tile in g.level_data.tiles {
              tile = {}
            }
          }
          if input_save {
            level_write_to_disk(&g.level_data, LEVEL_NAME)
          }
          if input_load {
            level_read_from_disk(&g.level_data, LEVEL_NAME)
          }
          if input_rotate {
            g.world_rotation += rl.GetFrameTime() * 80
          }
        }

        { // draw
          rl.BeginMode3D(g.camera)
          defer rl.EndMode3D()

          push_level_matrix(LEVEL_SIZE.xy)
          defer rlgl.PopMatrix()

          draw_level_grid(LEVEL_SIZE.xy)
          draw_level_tiles(g.level_data);
          draw_level_marker(g.level_data, level_editor.marker_position, level_editor.marker_size)
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
load_texture_png :: proc($path: string) -> rl.Texture {
  assert(strings.ends_with(path, "png"))

  when EMBED_ASSETS {
    data := #load(path)
    image := rl.LoadImageFromMemory(".png", raw_data(data), c.int(len(data)))
    defer rl.UnloadImage(image)
    return rl.LoadTextureFromImage(image)
  } else {
    full_path := fmt.tprintf("%s/%s", assets_path(), path)
    return rl.LoadTexture(strings.clone_to_cstring(full_path, context.temp_allocator))
  }
}
load_font_ttf :: proc($path: string, size: i32) -> rl.Font {
  assert(strings.ends_with(path, "ttf"))

  when EMBED_ASSETS {
    data := #load(path)
    return rl.LoadFontFromMemory(".ttf", raw_data(data), c.int(len(data)), size, nil, 0)
  } else {
    full_path := fmt.tprintf("%s/%s", assets_path(), path)
    return rl.LoadFontEx(strings.clone_to_cstring(full_path, context.temp_allocator), size, nil, 0)
  }
}

LEVEL_SIZE :: Vector3i32{ 10, 10, 5 }
Level_Data :: struct {
  tiles:      [LEVEL_SIZE.x*LEVEL_SIZE.y]Tile,
}
Tile :: struct {
  type:       enum u8 { EMPTY, DIRT },
  height:     u16,
}
level_read_from_disk :: proc(level_data: ^Level_Data, file_name: string) -> bool {
  full_path := strings.join({ assets_path(), file_name }, "/", context.temp_allocator)
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
// Returns the point in the middle of the top face of the tile
grid_to_world_position :: proc(grid_position: Vector2i32) -> (world_position: Vector3f32) {
  tile := g.level_data.tiles[grid_position_to_index(grid_position, LEVEL_SIZE.x)]
  world_position.x = TILE_OFFSET.x + f32(grid_position.x)
  world_position.y = TILE_OFFSET.y + f32(tile.height + 1) * TILE_STEP_HEIGHT
  world_position.z = TILE_OFFSET.z + f32(grid_position.y)
  return world_position
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
  rlgl.Rotatef(g.world_rotation, 0, 1, 0)
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
    position := grid_to_world_position(grid_position)
    position.y -= TILE_STEP_HEIGHT
    position.y *= 0.5
    size := Vector3f32{ 1, f32(tile.height) * TILE_STEP_HEIGHT, 1 }
    draw_cube_texture(g.texture_dirt, position, size, rl.WHITE)
  }
}
draw_level_marker :: proc(level_data: Level_Data, marker_position: Vector2i32, marker_size: Vector2i32 = {}) {
  for grid_position in level_positions_in_area(level_data, marker_position, marker_size) {
    position := grid_to_world_position(grid_position)
    position.y -= TILE_STEP_HEIGHT
    position.y += 0.05
    draw_cube_texture(g.texture_dirt, position, size = { 0.8, 0.15, 0.8 }, color = rl.RED)
  }
}
draw_level_selected_tiles :: proc(level_data: Level_Data, selected_tiles: []Vector2i32) {
  for grid_position in selected_tiles {
    position := grid_to_world_position(grid_position)
    position.y -= TILE_STEP_HEIGHT
    position.y += 0.05
    draw_cube_texture(g.texture_dirt, position, size = { 1, 0.1, 1 }, color = rl.BLUE)
  }
}
draw_level_units :: proc(level_data: Level_Data, units: []Unit) {
  for unit, unit_index in units {
    if unit.type == 0 { continue }

    rlgl.PushMatrix()
    rlgl.Translatef(unit.transform.position.x, unit.transform.position.y, unit.transform.position.z)
    rlgl.Rotatef(unit.transform.rotation, 0, 1, 0)
    rlgl.Scalef(unit.transform.scale.x, unit.transform.scale.y, unit.transform.scale.z)
    draw_cube_texture(g.texture_dirt, { 0, 0.25, 0.0 }, { 0.5, 1.0, 0.5 }, rl.GREEN)
    draw_cube_texture(g.texture_dirt, { 0, 0.25, 0.3 }, { 0.2, 0.2, 0.5 }, rl.DARKGREEN)
    rlgl.PopMatrix()

    // rlgl.PushMatrix()
    // rlgl.Translatef(unit.transform.position.x, unit.transform.position.y, unit.transform.position.z)
    // rlgl.Rotatef(direction_to_rotation(unit.direction), 0, 1, 0)
    // draw_cube_texture(game.texture_dirt, { 0, 0.25, 0.3 }, { 0.1, 0.1, 1.0 }, rl.RED)
    // rlgl.PopMatrix()
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
  current:    M,
  entered_at: time.Time,
  exited_at:  time.Time,
  entering:   bool,
  exiting:    bool,
  arena:      ^virtual.Arena,
}
mode_transition :: proc(mode: ^Mode($T), next: T) {
  mode.entered_at = {}
  mode.current    = next
  mode.exiting    = true
}
mode_update :: proc(mode: ^Mode($T), loc := #caller_location) {
  assert(mode.arena != nil, "mode.arena not initialized", loc = loc)
  mode.entering = mode.entered_at == {}
  if mode.entering {
    virtual.arena_free_all(mode.arena)
    mode.entered_at = time.now()
    mode.exiting    = false
  }
  if mode.exiting {
    mode.exiting   = false
    mode.exited_at = time.now()
  }
}

DIRECTION_VECTORS :: [Direction]Vector2i32{
  .NORTH = {  0, +1 },
  .WEST  = { +1,  0 },
  .SOUTH = {  0, -1 },
  .EAST  = { -1,  0 },
}
Direction :: enum u8 { NORTH, EAST, SOUTH, WEST }
vector_to_direction :: proc(vector: Vector2i32) -> Direction {
  if vector.y > 0 { return .NORTH }
  if vector.y < 0 { return .SOUTH }
  if vector.x < 0 { return .EAST }
  return .WEST;
}
vectors_to_direction :: proc(from, to: Vector2i32) -> Direction {
  return vector_to_direction(to - from)
}
direction_to_rotation :: proc(direction: Direction) -> f32 {
  return f32(direction) * -90;
}
vector_to_rotation :: proc(vector: Vector2f32) -> f32 {
  return 0;
}
direction_to_vector2 :: proc(direction: Direction) -> Vector2i32 {
  directions := DIRECTION_VECTORS
  result: Vector2i32
  result.x = directions[direction].x
  result.y = directions[direction].y
  return result
}
direction_to_vector3 :: proc(direction: Direction) -> Vector3f32 {
  directions := DIRECTION_VECTORS
  result: Vector3f32
  result.x = f32(directions[direction].x)
  result.z = f32(directions[direction].y)
  return result
}

Board :: struct {
  nodes: [LEVEL_SIZE.x*LEVEL_SIZE.y]Node,
  units: [16]Unit,
}
Transform :: struct {
  position:   Vector3f32,
  rotation:   f32,
  scale:      Vector3f32,
}
Movement_Type :: enum u8 { WALK, FLY, TELEPORT }
Node :: struct {
  grid_index: u32,
  previous:   i16,
  distance:   u16,
}
board_search :: proc(start_node: ^Node, board: ^Board, add_node: proc(from: ^Node, to: ^Node, user_data: rawptr) -> bool, user_data: rawptr, allocator := context.temp_allocator) -> [dynamic]Vector2i32 {
  result: [dynamic]Vector2i32
  result.allocator = allocator

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

      if add_node(node, next_node, user_data) {
        next_node.distance = node.distance + 1
        next_node.previous = i16(node.grid_index)
        queue.push_back(&check_next, next_node)
        append(&result, next_position)
      }
    }

    if queue.len(check_now) == 0 {
      temp := check_now
      check_now = check_next
      check_next = temp
    }
  }

  return result
}

Unit :: struct {
  type:         u8,
  position:   Vector2i32,
  direction:  Direction,
  movement:   Movement_Type,
  // stats
  move:       u8, // TODO: use Stat_Type
  jump:       u8, // TODO: use Stat_Type
  stats:      [Stat_Type]u16,
  // rendering infos
  transform:  Transform,
}
unit_set_stat :: proc(unit: ^Unit, stat: Stat_Type, value: u16, allow_exception: bool) {
  old_value := unit.stats[stat]
  if old_value == value {
    return
  }

  new_value := value
  if allow_exception {
    exception: Exception
    exception.type          = .VALUE_CHANGE
    exception.default_value = true
    exception.value         = true
    exception.from          = f32(old_value)
    exception.to            = f32(value)

    notification_post(Notification{ type = .STAT_WILL_CHANGE, stat = stat }, &exception)
    new_value = u16(math.floor(exception_compute_modified_value(exception)))

    if !exception.value || value == old_value {
      return;
    }
  }

  unit.stats[stat] = new_value
  notification_post(Notification{ type = .STAT_DID_CHANGE, stat = stat }, &{})
}
@(test)
test_unit_stats :: proc(t: ^testing.T) {
  unit: Unit;
  unit.stats[.HP] = 10
  unit_set_stat(&unit, .HP, 100, allow_exception = false)
  testing.expect_value(t, unit.stats[.HP], 100)

  _test_clamp_hp = true
  _test_prevent_hp_change = false
  unit.stats[.HP] = 10
  unit_set_stat(&unit, .HP, 100, allow_exception = true)
  testing.expect_value(t, unit.stats[.HP], 50)

  _test_clamp_hp = false
  _test_prevent_hp_change = true
  unit.stats[.HP] = 10
  unit_set_stat(&unit, .HP, 100, allow_exception = true)
  testing.expect_value(t, unit.stats[.HP], 10)
}
unit_move_sequence_prepare :: proc(unit: ^Unit, destination: Vector2i32, move_sequence: ^Move_Sequence, board: ^Board, level_data: ^Level_Data) {
  context.allocator = g.move_arena.allocator

  for move_step in move_sequence.steps {
    ease.flux_destroy(move_step.flux_map)
  }
  clear(&move_sequence.steps)
  move_sequence^ = {}

  move_positions: [dynamic]Vector2i32
  move_positions.allocator = context.temp_allocator
  node_grid_index := i16(grid_position_to_index(destination, LEVEL_SIZE.x))
  for node_grid_index > -1 {
    node := board.nodes[node_grid_index]
    append(&move_positions, grid_index_to_position(i32(node_grid_index), LEVEL_SIZE.xy))
    node_grid_index = node.previous
  }
  slice.reverse(move_positions[:])

  switch unit.movement {
    case .WALK: {
      previous_direction := unit.direction

      for index in 1 ..< len(move_positions) {
        from_position := move_positions[index-1]
        to_position   := move_positions[index]
        to_position_world := grid_to_world_position(to_position)

        direction := vectors_to_direction(from_position, to_position)
        if direction != previous_direction {
          move_step: Move_Step
          move_step.name           = "turn"
          move_step.from           = from_position
          move_step.to             = from_position
          move_step.direction_from = previous_direction
          move_step.direction_to   = direction
          unit_tween_rotation(&move_step, unit)
          append(&move_sequence.steps, move_step)
        }

        from_tile := level_data.tiles[grid_position_to_index(from_position, LEVEL_SIZE.x)]
        to_tile   := level_data.tiles[grid_position_to_index(to_position, LEVEL_SIZE.x)]
        if from_tile.height != to_tile.height {
          move_step: Move_Step
          move_step.name           = "jump"
          move_step.from           = from_position
          move_step.to             = to_position
          move_step.direction_from = previous_direction
          move_step.direction_to   = direction
          unit_tween_position(&move_step, unit, to_position_world)
          append(&move_sequence.steps, move_step)
        } else {
          move_step: Move_Step
          move_step.name           = "walk"
          move_step.from           = from_position
          move_step.to             = to_position
          move_step.direction_from = previous_direction
          move_step.direction_to   = direction
          move_step.flux_map       = ease.flux_init(f32)
          unit_tween_position(&move_step, unit, to_position_world)
          append(&move_sequence.steps, move_step)
        }

        previous_direction = direction
      }
    }
    case .FLY: {
      FLY_HEIGHT :: 5
      unit_direction := unit.direction

      from_position := move_positions[0]
      to_position   := move_positions[len(move_positions)-1]
      {
        move_step: Move_Step
        move_step.name           = "turn"
        move_step.from           = from_position
        move_step.to             = from_position
        move_step.direction_from = unit_direction
        move_step.direction_to   = vectors_to_direction(from_position, to_position)
        unit_tween_rotation(&move_step, unit)
        append(&move_sequence.steps, move_step)
      }
      {
        to_position_world := grid_to_world_position(from_position)
        to_position_world.y += FLY_HEIGHT

        move_step: Move_Step
        move_step.name           = "fly_up"
        move_step.from           = from_position
        move_step.to             = to_position
        move_step.direction_from = unit_direction
        move_step.direction_to   = vectors_to_direction(from_position, to_position)
        unit_tween_position(&move_step, unit, to_position_world)
        append(&move_sequence.steps, move_step)
      }

      {
        to_position_world := grid_to_world_position(to_position)
        to_position_world.y += FLY_HEIGHT

        move_step: Move_Step
        move_step.name           = "fly_horizontal"
        move_step.from           = from_position
        move_step.to             = to_position
        move_step.direction_from = unit_direction
        move_step.direction_to   = vectors_to_direction(from_position, to_position)
        unit_tween_position(&move_step, unit, to_position_world)
        append(&move_sequence.steps, move_step)
      }
      {
        to_position_world := grid_to_world_position(to_position)

        move_step: Move_Step
        move_step.name           = "fly_down"
        move_step.from           = from_position
        move_step.to             = to_position
        move_step.direction_from = unit_direction
        move_step.direction_to   = vectors_to_direction(from_position, to_position)
        unit_tween_position(&move_step, unit, to_position_world)
        append(&move_sequence.steps, move_step)
      }
    }
    case .TELEPORT: {
      unit_direction := unit.direction

      from_position := move_positions[0]
      to_position   := move_positions[len(move_positions)-1]
      {
        move_step: Move_Step
        move_step.name           = "dissapear"
        move_step.from           = from_position
        move_step.to             = from_position
        move_step.direction_from = unit_direction
        move_step.direction_to   = unit_direction
        unit_tween_scale(&move_step, unit, { 0, 0, 0 })
        append(&move_sequence.steps, move_step)
      }
      {
        move_step: Move_Step
        move_step.name           = "teleport"
        move_step.from           = from_position
        move_step.to             = to_position
        move_step.direction_from = unit_direction
        move_step.direction_to   = vectors_to_direction(from_position, to_position)
        unit_tween_position(&move_step, unit, grid_to_world_position(to_position), {})
        append(&move_sequence.steps, move_step)
      }
      {
        move_step: Move_Step
        move_step.name           = "appear"
        move_step.from           = from_position
        move_step.to             = to_position
        move_step.direction_from = unit_direction
        move_step.direction_to   = unit_direction
        unit_tween_scale(&move_step, unit, { 1, 1, 1 })
        append(&move_sequence.steps, move_step)
      }
    }
  }
  // for step in move_sequence.steps { log.debugf("- %v %v %v", step.name, step.direction_to, step.to) }
}
unit_move_sequence_execute :: proc(unit: ^Unit, move_sequence: ^Move_Sequence) -> bool {
  if len(move_sequence.steps) == 0 {
    return true;
  }

  if move_sequence.current_started_at == {} {
    move_sequence.current_started_at = time.now()
  }

  move_step := move_sequence.steps[move_sequence.current]

  ease.flux_update(&move_step.flux_map, f64(rl.GetFrameTime()))
  done := true
  for key, tween in move_step.flux_map.values {
    if tween.progress != 1 { done = false; break }
  }

  if done {
    unit.position       = move_step.to
    unit.direction      = move_step.direction_to
    if move_sequence.current < len(move_sequence.steps)-1 {
      move_sequence.current += 1
      move_sequence.current_started_at = time.now()
    } else {
      return true
    }
  }

  return false
}

unit_tween_rotation :: proc(move_step: ^Move_Step, unit: ^Unit, duration: time.Duration = 300 * time.Millisecond) {
  from_vector   := linalg.array_cast(direction_to_vector2(move_step.direction_from), f32)
  to_rotation   := direction_to_rotation(move_step.direction_to)
  to_vector     := linalg.array_cast(direction_to_vector2(move_step.direction_to), f32)

  perpendicular := Vector2f32{ from_vector.y, -from_vector.x }
  rotation := to_rotation
  if glsl.dot(to_vector, perpendicular) > 0 {
    rotation += 360
  }

  move_step.flux_map = ease.flux_init(f32)
  _ = ease.flux_to(&move_step.flux_map, &unit.transform.rotation, rotation, .Quadratic_In, duration)
}
unit_tween_position :: proc(move_step: ^Move_Step, unit: ^Unit, destination: Vector3f32, duration: time.Duration = 500 * time.Millisecond) {
  move_step.flux_map = ease.flux_init(f32)
  _ = ease.flux_to(&move_step.flux_map, &unit.transform.position.x, destination.x, .Linear, duration)
  _ = ease.flux_to(&move_step.flux_map, &unit.transform.position.y, destination.y, .Linear, duration)
  _ = ease.flux_to(&move_step.flux_map, &unit.transform.position.z, destination.z, .Linear, duration)
}
unit_tween_scale :: proc(move_step: ^Move_Step, unit: ^Unit, scale: Vector3f32, duration: time.Duration = 500 * time.Millisecond) {
  move_step.flux_map = ease.flux_init(f32)
  _ = ease.flux_to(&move_step.flux_map, &unit.transform.scale.x, scale.x, .Quadratic_In, duration)
  _ = ease.flux_to(&move_step.flux_map, &unit.transform.scale.y, scale.y, .Quadratic_In, duration)
  _ = ease.flux_to(&move_step.flux_map, &unit.transform.scale.z, scale.z, .Quadratic_In, duration)
}

f32_approx :: proc(a, b: f32) -> bool {
  return math.abs(b - a) < math.max(0.000001 * math.max(math.abs(a), math.abs(b)), math.F32_EPSILON * 8)
}
wrap_around :: proc(value, increment, max: int) -> int {
  return (value - increment + max) % max;
}
to_temp_cstring :: proc(str: string) -> cstring {
  return strings.clone_to_cstring(str, context.temp_allocator)
}

Menu_Item :: struct {
  text:     string,
  locked:   bool,
}
menu_open :: proc(title: string, items: []Menu_Item, selected: int = 0) {
  g.battle.menu_title = title

  clear(&g.battle.menu_items)
  context.allocator = g.battle_mode_arena.allocator
  for item in items {
    append(&g.battle.menu_items, item)
  }

  for i in 0 ..< len(items) { // Find the first unlocked item and select it
    g.battle.menu_selected = selected + i
    if !g.battle.menu_items[g.battle.menu_selected].locked { break }
  }

  _ = ease.flux_to(&g.battle.menu_flux_map, &g.battle.menu_position.x, 0, .Quadratic_In, 300 * time.Millisecond)
}
menu_update :: proc() -> (confirm: bool) {
  if g.inputs.move.value.y != 0 {
    for _ in 0 ..< len(g.battle.menu_items) { // Jump to the next unlocked item
      g.battle.menu_selected = wrap_around(g.battle.menu_selected, int(g.inputs.move.value.y), len(g.battle.menu_items))
      if !g.battle.menu_items[g.battle.menu_selected].locked { break }
    }
  }

  return g.inputs.confirm
}
menu_close :: proc() {
  _ = ease.flux_to(&g.battle.menu_flux_map, &g.battle.menu_position.x, g.battle.menu_size.x, .Quadratic_In, 300 * time.Millisecond)
}

Static_Arena :: struct($size: int) {
  name:              string,
  arena:             virtual.Arena,
  allocator:         mem.Allocator,
  buffer:            [size]byte,
}
static_arena_init :: proc(arena: ^Static_Arena($size), name: $string) {
  alloc_err := virtual.arena_init_buffer(&arena.arena, arena.buffer[:])
  assert(alloc_err == .None, "Couldn't allocate static arena")
  arena.name                = name
  arena.allocator.procedure = static_arena_allocator_proc
  arena.allocator.data      = arena
}
static_arena_imgui_progress_bar :: proc(arena: Static_Arena(($size))) {
  ImGui.ProgressBar(
    f32(arena.arena.total_used) / f32(arena.arena.total_reserved),
    { 200, 20 },
    fmt.ctprintf("%s: %v/%v", arena.name, arena.arena.total_used, arena.arena.total_reserved)
  )
}
@(no_sanitize_address)
static_arena_allocator_proc :: proc(
  allocator_data: rawptr, mode: mem.Allocator_Mode,
  size, alignment: int,
  old_memory: rawptr, old_size: int,
  loc := #caller_location
) -> (data: []byte, err: runtime.Allocator_Error) {
  arena := cast(^Static_Arena(0)) allocator_data
  data, err = virtual.arena_allocator_proc(&arena.arena, mode, size, alignment, old_memory, old_size, loc)
  if err != .None {
    log.errorf("Allocation failed on arena \"%v\" (%v/%v): %v. (mode: %v, size: %v)", arena.name, arena.arena.total_used, arena.arena.total_reserved, err, mode, size, location = loc)
    when ODIN_DEBUG { intrinsics.debug_trap() }
  }
  return data, err
}

// Placeholder for the actual exception and notification system since i'm not sure i'll implement it at all...
// TODO: I've implemented it close to the original OOP version from tutorial, but i would probably do it very differently nowadays...
Stat_Type :: enum u8 {
  LVL, // Level
  EXP, // Experience
  HP,  // Hit Points
  MHP, // Max Hit Points
  MP,  // Magic Points
  MMP, // Max Magic Points
  ATK, // Physical Attack
  DEF, // Physical Defense
  MAT, // Magic Attack
  MDF, // Magic Defense
  EVD, // Evade
  RES, // Status Resistance
  SPD, // Speed
  MOV, // Move Range
  JMP, // Jump Height
}

Exception :: struct {
  type:           enum u8 { VALUE_CHANGE, MATCH },
  default_value:  bool,
  value:          bool,
  from:           f32,
  to:             f32,
  modifiers:      [dynamic]Modifier,
}
exception_compute_modified_value :: proc(exception: Exception) -> f32 {
  result := exception.to

  sorted_modifiers := slice.clone(exception.modifiers[:], context.temp_allocator)
  sort_value_modifier :: proc(a, b: Modifier) -> int {
    return int(a.sort_order - b.sort_order)
  }
  sort.bubble_sort_proc(sorted_modifiers, sort_value_modifier)
  for modifier in exception.modifiers {
    result = modifier_compute_value(modifier, result)
  }

  return result
}
@(test)
test_exceptions :: proc(t: ^testing.T) {
  exception: Exception;
  exception.type = .VALUE_CHANGE
  exception.from = 5
  exception.to   = 10
  append(&exception.modifiers, Modifier{ type = .MIN_VALUE, sort_order = 0, min = 9 })
  testing.expect_value(t, exception_compute_modified_value(exception), 9)
  append(&exception.modifiers, Modifier{ type = .ADD_VALUE, sort_order = 1, to_add = 2 })
  testing.expect_value(t, exception_compute_modified_value(exception), 11)
  append(&exception.modifiers, Modifier{ type = .MULTIPLY_VALUE, sort_order = 2, to_multiply = 2 })
  testing.expect_value(t, exception_compute_modified_value(exception), 22)
  append(&exception.modifiers, Modifier{ type = .CLAMP_VALUE, sort_order = 3, max = 14 })
  testing.expect_value(t, exception_compute_modified_value(exception), 14)
}

Modifier :: struct {
  type:         enum u8 { ADD_VALUE, MULTIPLY_VALUE, MIN_VALUE, MAX_VALUE, CLAMP_VALUE },
  sort_order:   int,
  to_add:       f32,
  to_multiply:  f32,
  min:          f32,
  max:          f32,
}
modifier_compute_value :: proc(modifier: Modifier, value: f32) -> (result: f32) {
  switch modifier.type {
    case .ADD_VALUE:      { result = value + modifier.to_add }
    case .MULTIPLY_VALUE: { result = value * modifier.to_multiply }
    case .MIN_VALUE:      { result = min(value, modifier.min) }
    case .MAX_VALUE:      { result = max(value, modifier.max) }
    case .CLAMP_VALUE:    { result = clamp(value, modifier.min, modifier.max) }
  }
  return result
}

Notification :: struct {
  type:   enum u8 { STAT_WILL_CHANGE, STAT_DID_CHANGE },
  stat:   Stat_Type,
}
notification_post :: proc(notification: Notification, exception: ^Exception) {
  if _test_prevent_hp_change {
    exception.value = !exception.default_value
    return
  }
  if _test_clamp_hp {
    append(&exception.modifiers, Modifier{ type = .CLAMP_VALUE, sort_order = 0, min = 0, max = 50 })
    return
  }
}
_test_prevent_hp_change: bool
_test_clamp_hp: bool
