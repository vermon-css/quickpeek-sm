#include <sourcemod>
#include <sdktools>
#include <clientprefs>

#define JL_OPCODE 0x8c
#define JNZ_OPCODE 0x85
#define NOP_OPCODE 0x90

#define EF_NODRAW 32

public Plugin myinfo = {
	name = "QuickPeek",
	author = "VerMon",
	description = "Observe other players' actions while in-game",
	version = "1.1.1",
	url = "https://steamcommunity.com/profiles/76561198141196062"
}

enum {
	ACTION_NONE,
	ACTION_START,
	ACTION_STOP,
	ACTION_NEXT_TARGET,
	ACTION_PREV_TARGET,
	ACTION_NEXT_TARGET_OR_STOP
}

enum struct Offsets {
	int base_player_delay;
	int base_player_replay_end;
	int base_player_replay_entity;
	int base_client_entity_index;
	int base_client_delta_tick;
	int game_client_send_sound_jnz;
	int base_player_spawn_stop_replay_mode_call;
}

Offsets offsets;

Handle sync_hud;

Handle get_client;
Handle send_weapon_anim;

// since different engines have their own values, we need this instead of #define
int act_vm_primary_attack;

// used only for plugin unload
char stop_replay_mode_call[6];

ConVar sv_stressbots;

float player_data_hud_update_time[MAXPLAYERS + 1];
int player_data_targets[MAXPLAYERS + 1][MAXPLAYERS];
int player_data_targets_count[MAXPLAYERS];
int player_data_last_target[MAXPLAYERS + 1];
int player_data_old_buttons[MAXPLAYERS + 1];
int player_data_queue_action[MAXPLAYERS + 1];
bool player_data_block_angles[MAXPLAYERS + 1];

public void OnPluginStart() {
	GameData game_data = LoadGameConfigFile("quickpeek.games");
	load_offsets(game_data);

	// for example, CS:S v34 has 178
	act_vm_primary_attack = GetEngineVersion() != Engine_SourceSDK2006 ? 180 : 178;

	int send_sound = view_as<int>(game_data.GetMemSig("game_client_send_sound"));
	StoreToAddress(view_as<Address>(send_sound + offsets.game_client_send_sound_jnz), JL_OPCODE, NumberType_Int8, true);

	int spawn_player = view_as<int>(game_data.GetMemSig("base_player_spawn"));
	
	for (int i = 0; i < 6; ++i) {
		stop_replay_mode_call[i] = LoadFromAddress(view_as<Address>(spawn_player + offsets.base_player_spawn_stop_replay_mode_call + i), NumberType_Int8);
		StoreToAddress(view_as<Address>(spawn_player + offsets.base_player_spawn_stop_replay_mode_call + i), NOP_OPCODE, NumberType_Int8, true);
	}

	StartPrepSDKCall(SDKCall_Server);
	PrepSDKCall_SetFromConf(game_data, SDKConf_Virtual, "base_server_get_client");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_ByValue);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_ByValue);
	get_client = EndPrepSDKCall();

	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(game_data, SDKConf_Virtual, "base_combat_weapon_send_weapon_anim");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_ByValue);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_ByValue);
	send_weapon_anim = EndPrepSDKCall();

	ConVar sv_maxreplay = FindConVar("sv_maxreplay");
	sv_maxreplay.FloatValue = 1.0;

	// enable peeking on fakeplayers
	sv_stressbots = FindConVar("sv_stressbots");
	sv_stressbots.Flags = 0;
	sv_stressbots.BoolValue = true;

	RegConsoleCmd("qpeek", quickpeek_console_command);

	AddCommandListener(hold_quickpeek_command_listener, "+qpeek");
	AddCommandListener(unhold_quickpeek_command_listener, "-qpeek")

	RegClientCookie("quickpeek_block_angles", "Block turning while peeking", CookieAccess_Protected);

	sync_hud = CreateHudSynchronizer();

	if (IsServerProcessing())
		for (int i = 1; i <= MaxClients; ++i)
			if (IsClientInGame(i))
				OnClientPutInServer(i);
}

public void OnPluginEnd() {
	for (int i = 1; i <= MaxClients; ++i)
		if (IsClientInGame(i) && IsPlayerAlive(i) && peek_target(i))
				stop_peeking(i);

	GameData game_data = LoadGameConfigFile("quickpeek.games");

	int send_sound = view_as<int>(game_data.GetMemSig("game_client_send_sound"));
	StoreToAddress(view_as<Address>(send_sound + offsets.game_client_send_sound_jnz), JNZ_OPCODE, NumberType_Int8, true);

	int spawn_player = view_as<int>(game_data.GetMemSig("base_player_spawn"));

	for (int i = 0; i < 6; ++i)
		StoreToAddress(view_as<Address>(spawn_player + offsets.base_player_spawn_stop_replay_mode_call + i), stop_replay_mode_call[i], NumberType_Int8, true);	
}

public void OnClientPutInServer(int index) {
	player_data_targets_count[index] = 0;
	player_data_last_target[index] = 0;
	player_data_hud_update_time[index] = 0.0;
	player_data_old_buttons[index] = 0;
	player_data_queue_action[index] = ACTION_NONE;

	if (!AreClientCookiesCached(index))
		player_data_block_angles[index] = true;
}

public void OnClientCookiesCached(int index) {
	Cookie cookie = FindClientCookie("quickpeek_block_angles");

	char buf[4];
	GetClientCookie(index, cookie, buf, sizeof(buf));

	if (strlen(buf) == 0)
		IntToString(1, buf, sizeof(buf));

	player_data_block_angles[index] = view_as<bool>(StringToInt(buf));
}

public void OnClientDisconnect(int index) {
	int client = get_base_client(index);
	StoreToAddress(view_as<Address>(client + offsets.base_client_entity_index), index, NumberType_Int32, false);
}

public Action OnPlayerRunCmd(int index, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& sub_type, int& cmd_num, int& tick_count, int& seed, int mouse[2]) {
	if (!IsPlayerAlive(index) || !peek_target(index))
		return Plugin_Continue;

	if (player_data_queue_action[index] != ACTION_STOP && player_data_queue_action[index] != ACTION_NEXT_TARGET_OR_STOP)
		if (buttons & IN_ATTACK && (player_data_old_buttons[index] & IN_ATTACK == 0))
			player_data_queue_action[index] = ACTION_NEXT_TARGET;
		else if (buttons & IN_ATTACK2 && (player_data_old_buttons[index] & IN_ATTACK2 == 0))
			player_data_queue_action[index] = ACTION_PREV_TARGET;

	player_data_old_buttons[index] = buttons;
	
	buttons &= ~IN_ATTACK;
	buttons &= ~IN_ATTACK2;

	weapon = 0;

	if (player_data_block_angles[index]) {
		GetClientEyeAngles(index, angles);
		TeleportEntity(index, NULL_VECTOR, angles, NULL_VECTOR);
	}

	return Plugin_Continue;
}

public void OnGameFrame() {
	for (int i = 1; i <= MaxClients; ++i) {
		if (!IsClientInGame(i))
			continue;

		int target = peek_target(i);

		if (player_data_queue_action[i] != ACTION_STOP) {
			if (IsPlayerAlive(i)) {
				if (target && !is_valid_target(target))
					// peek target is no longer valid (dead, just leaved the game, etc.)
					player_data_queue_action[i] = ACTION_NEXT_TARGET_OR_STOP;
			}
			else if (target)
				// our player just died
				player_data_queue_action[i] = ACTION_STOP;
			else
				player_data_queue_action[i] = ACTION_NONE;
		}

		int client = get_base_client(i);
		int delta_tick = LoadFromAddress(view_as<Address>(client + offsets.base_client_delta_tick), NumberType_Int32);

		// check whether client is fully updated or not to prevent host error (missing client entity)
		if (delta_tick != -1) {
			switch (player_data_queue_action[i]) {
				case ACTION_START: {
					player_data_targets_count[i] = 0;
					
					target = player_data_last_target[i];

					if (!target || !is_valid_target(target))
						target = find_new_target(i);
						
					if (target) {
						// init array
						player_data_targets[i][0] = target;
						player_data_targets_count[i] = 1;
						start_peeking(i, target);
					}
				}

				case ACTION_STOP:
					stop_peeking(i);

				case ACTION_NEXT_TARGET: {
					int new_target = 0;

					// last element: try to find another nearest target
					if (player_data_targets[i][player_data_targets_count[i] - 1] == target) {
						new_target = find_new_target(i);
						
						if (new_target)
							add_target(i, new_target);
					}

					if (!new_target) {
						int idx = get_used_target_index(i, target);
						new_target = cycle_used_targets(i, idx);
					}

					if (new_target) {
						switch_peek_target(i, new_target);
						target = new_target;
					}
				}

				case ACTION_PREV_TARGET: {
					int new_target = 0;

					// first element: try to find another farest target
					if (player_data_targets[i][0] == target) {
						new_target = find_new_target(i, false);

						if (new_target)
							add_target(i, new_target, false);
					}

					if (!new_target) {
						int idx = get_used_target_index(i, target);
						new_target = cycle_used_targets(i, idx, true);
					}

					if (new_target) {
						switch_peek_target(i, new_target);
						target = new_target;
					}
				}

				case ACTION_NEXT_TARGET_OR_STOP: {
					int idx = get_used_target_index(i, target);
					int new_target = cycle_used_targets(i, idx);

					if (!new_target) {
						new_target = find_new_target(i);

						if (new_target)
							add_target(i, new_target);
					}

					if (new_target) {
						remove_target(i, idx);
						switch_peek_target(i, new_target);
						target = new_target;
					}
					else
						stop_peeking(i);
				}
			}

			player_data_last_target[i] = target;
			player_data_queue_action[i] = ACTION_NONE;
		}

		// IsClientInGame means a target can be disconnected and if we can't immediately process ACTION_NEXT_TARGET_OR_STOP after that
		if (target && GetGameTime() >= player_data_hud_update_time[i] && IsClientInGame(target)) {
			char buf[MAX_NAME_LENGTH];
			GetClientName(target, buf, sizeof(buf));
			
			SetHudTextParams(-1.0, 0.65, 1.05, 255, 255, 255, 0, 0, 0.0, 0.0, 0.0);
			ShowSyncHudText(i, sync_hud, buf);

			player_data_hud_update_time[i] = GetGameTime() + 1.0;
		}
	}
}

Action quickpeek_console_command(int index, int args) {
	if (args > 0) {
		char buf[16];
		GetCmdArg(1, buf, sizeof(buf));

		if (strcmp(buf, "angles", false) == 0) {
			player_data_block_angles[index] = !player_data_block_angles[index];

			Cookie cookie = FindClientCookie("quickpeek_block_angles");
			cookie.Set(index, player_data_block_angles[index] ? "1" : "0");

			return Plugin_Handled;
		}

		return Plugin_Continue;
	}
	
	if (!IsPlayerAlive(index))
		return Plugin_Handled;

	player_data_queue_action[index] = peek_target(index) ? ACTION_STOP : ACTION_START;
	
	return Plugin_Handled;
}

Action hold_quickpeek_command_listener(int index, const char[] command, int args) {
	if (!IsPlayerAlive(index))
		return Plugin_Handled;

	if (!peek_target(index))
		player_data_queue_action[index] = ACTION_START;

	return Plugin_Handled;
}

Action unhold_quickpeek_command_listener(int index, const char[] command, int args) {
	if (!IsPlayerAlive(index))
		return Plugin_Handled;

	player_data_queue_action[index] = peek_target(index) ? ACTION_STOP : ACTION_NONE;
	
	return Plugin_Handled;
}

static bool is_valid_target(int index) {
	return IsClientInGame(index) && IsPlayerAlive(index) && !(GetEntProp(index, Prop_Send, "m_fEffects") & EF_NODRAW) && (!IsFakeClient(index) || sv_stressbots.BoolValue)
}

static int bound_target_index(int index, int target_index) {
	if (target_index >= player_data_targets_count[index])
		return 0;

	if (target_index < 0)
		return player_data_targets_count[index] - 1;

	return target_index;
}

static int cycle_used_targets(int index, int start_index, bool reverse=false) {
	int step = 1 - 2 * view_as<int>(reverse);
	int idx = bound_target_index(index, start_index + step);

	while (idx != start_index) {
		if (is_valid_target(player_data_targets[index][idx]))
			return player_data_targets[index][idx];
			
		idx = bound_target_index(index, idx + step);
	}

	return 0;
}

static void start_peeking(int index, int target) {
	SetEntDataFloat(index, offsets.base_player_delay, 0.01);
	SetEntDataFloat(index, offsets.base_player_replay_end, 9999999.0);
	SetEntData(index, offsets.base_player_replay_entity, target, 4, false);

	kill_cam_message(index, 4, target, index);
	fix_peek_weapon_anim(target);
	
	player_data_hud_update_time[index] = 0.0;
}

static void stop_peeking(int index) {	
	SetEntDataFloat(index, offsets.base_player_delay, 0.0, false);
	SetEntDataFloat(index, offsets.base_player_replay_end, -1.0, false);
	SetEntData(index, offsets.base_player_replay_entity, 0, 4, false);

	kill_cam_message(index, 0, 0, 0);
	ClearSyncHud(index, sync_hud);
}

static void switch_peek_target(int index, int target) {
	SetEntData(index, offsets.base_player_replay_entity, target, 4, false);

	kill_cam_message(index, 4, target, index);
	fix_peek_weapon_anim(target);

	int client = get_base_client(index);

	StoreToAddress(view_as<Address>(client + offsets.base_client_delta_tick), -1, NumberType_Int32, false);
	StoreToAddress(view_as<Address>(client + offsets.base_client_entity_index), target, NumberType_Int32, false);

	player_data_hud_update_time[index] = 0.0;
}

static void add_target(int index, int target, bool back=true) {
	int pos = view_as<int>(!back) * player_data_targets_count[index];

	while (pos--)
		player_data_targets[index][pos + 1] = player_data_targets[index][pos];

	pos = view_as<int>(back) * player_data_targets_count[index];
	player_data_targets[index][pos] = target;
	player_data_targets_count[index] += 1;
}

static void remove_target(int index, int remove_index) {
	while (++remove_index != player_data_targets_count[index])
		player_data_targets[index][remove_index - 1] = player_data_targets[index][remove_index];
		
	player_data_targets_count[index] -= 1;
}

static bool is_used_target(int index, int target) {
	for (int i = 0; i < player_data_targets_count[index]; ++i)
		if (player_data_targets[index][i] == target)
			return true;
			
	return false;
}

static int get_used_target_index(int index, int target) {
	for (int i = 0; i < player_data_targets_count[index]; ++i)
		if (player_data_targets[index][i] == target)
			return i;
			
	return -1;
}

static int find_new_target(int index, bool nearest=true) {
	int target = 0;
	float best_distance = 999999999999999.0 * view_as<int>(nearest);
	
	float origin[3];
	GetClientAbsOrigin(index, origin);
	
	for (int i = 1; i <= MaxClients; ++i) {
		if (index == i || is_used_target(index, i) || !is_valid_target(i))
			continue;

		float v[3];
		GetClientAbsOrigin(i, v);

		float dist = GetVectorDistance(origin, v) * (2 * view_as<int>(nearest) - 1);
		
		if (dist < best_distance) {
			best_distance = dist;
			target = i;
		}
	}

	return target;
}

static int peek_target(int index) {
	return GetEntData(index, offsets.base_player_replay_entity, 4);
}

static int get_base_client(int index) {
	return SDKCall(get_client, index - 1) - 4;
}			

static void kill_cam_message(int index, int mode, int first, int second) {
	BfWrite bf = view_as<BfWrite>(StartMessageOne("KillCam", index, USERMSG_RELIABLE | USERMSG_BLOCKHOOKS));
	bf.WriteByte(mode);
	bf.WriteByte(first);
	bf.WriteByte(second);
	EndMessage();
}

// it fixes viewmodels dissapearing, e.g. usp
static void fix_peek_weapon_anim(int index) {
	int active_weapon = GetEntPropEnt(index, Prop_Send, "m_hActiveWeapon");
	if (active_weapon != -1) {
		int sequence = GetEntProp(active_weapon, Prop_Send, "m_nSequence");
		if (sequence == 6 || sequence == 14)
			SDKCall(send_weapon_anim, active_weapon, act_vm_primary_attack);
	}
}

static void load_offsets(GameData gd) {
	offsets.base_player_delay = gd.GetOffset("base_player_delay");
	// we assume other variables are near
	offsets.base_player_replay_end = offsets.base_player_delay + 0x4;
	offsets.base_player_replay_entity = offsets.base_player_replay_end + 0x4;

	offsets.base_client_entity_index = gd.GetOffset("base_client_entity_index");
	offsets.base_client_delta_tick = gd.GetOffset("base_client_delta_tick");

	offsets.game_client_send_sound_jnz = gd.GetOffset("game_client_send_sound_jnz");
	offsets.base_player_spawn_stop_replay_mode_call = gd.GetOffset("base_player_spawn_stop_replay_mode_call");
}
