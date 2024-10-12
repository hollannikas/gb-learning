INCLUDE "hardware.inc"

SECTION "VBlank Interrupt", ROM0[$0040]
VBlankInterrupt:
	push af
	push bc
	push de
	push hl
	jp VBlankHandler

SECTION "Header", ROM0[$100]

    jp EntryPoint

    ds $150 - @, 0 ; Make room for the header

EntryPoint:
    ; Do not turn the LCD off outside of VBlank
WaitVBlank:
    ld a, [rLY]
    cp 144
    jp c, WaitVBlank

    ; Turn the LCD off
    ld a, 0
    ld [rLCDC], a

    ; Copy the tile data
    ld de, Tiles
    ld hl, $9000
    ld bc, TilesEnd - Tiles
    call Memcopy

    ; Copy the tilemap
    ld de, Tilemap
    ld hl, $9800
    ld bc, TilemapEnd - Tilemap
    call Memcopy

    ; Copy the player tile
    ld de, Player
    ld hl, $8000
    ld bc, PlayerEnd - Player
    call Memcopy

    ld a, 0
    ld b, 160
    ld hl, _OAMRAM
ClearOam:
    ld [hli], a
    dec b
    jp nz, ClearOam

    ; Initialize the player sprite in OAM
    ld hl, _OAMRAM
    ld a, 128 + 16
    ld [hli], a
    ld a, 16 + 8
    ld [hli], a
    ld a, 0
    ld [hli], a
    ld [hli], a

    ; Turn the LCD on
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJON
    ld [rLCDC], a

    ; During the first (blank) frame, initialize display registers
    ld a, %11100100
    ld [rBGP], a
    ld a, %11100100
    ld [rOBP0], a

    ; Initialize global variables
    xor a
    ld [wFrameCounter], a
    ld [wCurKeys], a
    ld [wNewKeys], a

Main:
    ; Wait until it's *not* VBlank
    ld a, [rLY]
    cp 144
    jp nc, Main
WaitVBlank2:
    ld a, [rLY]
    cp 144
    jp c, WaitVBlank2

    ld a, [wFrameCounter]
    inc a
    ld [wFrameCounter], a
    cp a, 6 ; Every 6 frames (10 times per second), run the following code
    jp nz, Main

    ; Reset the frame counter back to 0
    ld a, 0
    ld [wFrameCounter], a

    ; Check the current keys every frame and move left or right.
    call UpdateKeys

    ; First, check if the left button is pressed.
CheckLeft:
    ld a, [wCurKeys]
    and a, PADF_LEFT
    jp z, CheckRight
Left:
    call TogglePlayerSprite
    ; Move the player one tile to the left.
    ld a, [_OAMRAM + 1]
    sub a, 8
    ; If we've already hit the edge of the playfield, don't move.
    cp a, 8
    jp z, Main
    ld [_OAMRAM + 1], a
    jp Main

    ; Then check the right button.
CheckRight:
    ld a, [wCurKeys]
    and a, PADF_RIGHT
    jp z, CheckDown
Right:
    call TogglePlayerSprite
    ; Move the player one pixel to the right.
    ld a, [_OAMRAM + 1]
    add a, 8
    ; If we've already hit the edge of the playfield, don't move.
    cp a, $70
    jp z, Main
    ld [_OAMRAM + 1], a
    jp Main

CheckDown:
    ld a, [wCurKeys]
    and a, PADF_DOWN
    jp z, CheckUp
Down:
    call TogglePlayerSprite
    ; Move the player one pixel to the left.
    ld a, [_OAMRAM]
    add a, 8
    ; If we've already hit the edge of the playfield, don't move.
    cp a, $98
    jp z, Main
    ld [_OAMRAM], a
    jp Main

CheckUp:
    ld a, [wCurKeys]
    and a, PADF_UP
    jp z, Main
Up:
    call TogglePlayerSprite
    ; Move the player one pixel to the left.
    ld a, [_OAMRAM]
    sub a, 8
    ; If we've already hit the edge of the playfield, don't move.
    cp a, $10
    jp z, Main
    ld [_OAMRAM], a
    jp Main

UpdateKeys:
    ; Poll half the controller
    ld a, P1F_GET_BTN
    call .onenibble
    ld b, a ; B7-4 = 1; B3-0 = unpressed buttons
    
    ; Poll the other half
    ld a, P1F_GET_DPAD
    call .onenibble
    swap a ; A3-0 = unpressed directions; A7-4 = 1
    xor a, b ; A = pressed buttons + directions
    ld b, a ; B = pressed buttons + directions
    
    ; And release the controller
    ld a, P1F_GET_NONE
    ldh [rP1], a
    
    ; Combine with previous wCurKeys to make wNewKeys
    ld a, [wCurKeys]
    xor a, b ; A = keys that changed state
    and a, b ; A = keys that changed to pressed
    ld [wNewKeys], a
    ld a, b
    ld [wCurKeys], a
    ret
    
    .onenibble
    ldh [rP1], a ; switch the key matrix
    call .knownret ; burn 10 cycles calling a known ret
    ldh a, [rP1] ; ignore value while waiting for the key matrix to settle
    ldh a, [rP1]
    ldh a, [rP1] ; this read counts
    or a, $F0 ; A7-4 = 1; A3-0 = unpressed keys
    .knownret
    ret

; Toggle the player sprite tile number between 0 and 1.
TogglePlayerSprite:
    push hl
    ld hl, _OAMRAM+2
    ld a, [hl]
    xor 1
    ld [hl], a
    pop hl
    ret

; Copy bytes from one area to another.
; @param de: Source
; @param hl: Destination
; @param bc: Length
Memcopy:
    ld a, [de]
    ld [hli], a
    inc de
    dec bc
    ld a, b
    or a, c
    jp nz, Memcopy
    ret

; Convert a pixel position to a tilemap address
; hl = $9800 + X + Y * 32
; @param b: X
; @param c: Y
; @return hl: tile address
GetTileByPixel:
    ; First, we need to divide by 8 to convert a pixel position to a tile position.
    ; After this we want to multiply the Y position by 32.
    ; These operations effectively cancel out so we only need to mask the Y value.
    ld a, c
    and a, %11111000
    ld l, a
    ld h, 0
    ; Now we have the position * 8 in hl
    add hl, hl ; position * 16
    add hl, hl ; position * 32
    ; Convert the X position to an offset.
    ld a, b
    srl a ; a / 2
    srl a ; a / 4
    srl a ; a / 8
    ; Add the two offsets together.
    add a, l
    ld l, a
    adc a, h
    sub a, l
    ld h, a
    ; Add the offset to the tilemap's base address, and we are done!
    ld bc, $9800
    add hl, bc
    ret

SECTION "VBlank Handler", ROM0
VBlankHandler:
	; Now we just have to `pop` those registers and return!
	pop hl
	pop de
	pop bc
	pop af
	reti

Tiles:
    dw `33333333
    dw `33333333
    dw `33333333
    dw `33322222
    dw `33322222
    dw `33322222
    dw `33322211
    dw `33322211
    dw `33333333
    dw `33333333
    dw `33333333
    dw `22222222
    dw `22222222
    dw `22222222
    dw `11111111
    dw `11111111
    dw `33333333
    dw `33333333
    dw `33333333
    dw `22222333
    dw `22222333
    dw `22222333
    dw `11222333
    dw `11222333
    dw `33333333
    dw `33333333
    dw `33333333
    dw `33333333
    dw `33333333
    dw `33333333
    dw `33333333
    dw `33333333
    dw `33322211
    dw `33322211
    dw `33322211
    dw `33322211
    dw `33322211
    dw `33322211
    dw `33322211
    dw `33322211
    dw `22222222
    dw `20000000
    dw `20111111
    dw `20111111
    dw `20111111
    dw `20111111
    dw `22222222
    dw `33333333
    dw `22222223
    dw `00000023
    dw `11111123
    dw `11111123
    dw `11111123
    dw `11111123
    dw `22222223
    dw `33333333
    dw `11222333
    dw `11222333
    dw `11222333
    dw `11222333
    dw `11222333
    dw `11222333
    dw `11222333
    dw `11222333
    dw `00000000
    dw `00000000
    dw `00000000
    dw `00000000
    dw `00000000
    dw `00000000
    dw `00000000
    dw `00000000
    dw `11001100
    dw `11111111
    dw `11111111
    dw `21212121
    dw `22222222
    dw `22322232
    dw `23232323
    dw `33333333
    ; Paste your logo here:
    dw `33000000
    dw `33000000
    dw `33000000
    dw `33000000
    dw `33111100
    dw `33111100
    dw `33111111
    dw `33111111
    dw `33331111
    dw `00331111
    dw `00331111
    dw `00331111
    dw `00331111
    dw `00331111
    dw `11331111
    dw `11331111
    dw `11333300
    dw `11113300
    dw `11113300
    dw `11113300
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `00003333
    dw `00000033
    dw `00000033
    dw `00000033
    dw `11000033
    dw `11000033
    dw `11111133
    dw `11111133
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11330000
    dw `11330000
    dw `11330000
    dw `33330000
    dw `11113311
    dw `11113311
    dw `00003311
    dw `00003311
    dw `00003311
    dw `00003311
    dw `00003311
    dw `00333311
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11113333
    ; digits
    ; 0
    dw `33333333
    dw `33000033
    dw `30033003
    dw `30033003
    dw `30033003
    dw `30033003
    dw `33000033
    dw `33333333
    ; 1
    dw `33333333
    dw `33300333
    dw `33000333
    dw `33300333
    dw `33300333
    dw `33300333
    dw `33000033
    dw `33333333
    ; 2
    dw `33333333
    dw `33000033
    dw `30330003
    dw `33330003
    dw `33000333
    dw `30003333
    dw `30000003
    dw `33333333
    ; 3
    dw `33333333
    dw `30000033
    dw `33330003
    dw `33000033
    dw `33330003
    dw `33330003
    dw `30000033
    dw `33333333
    ; 4
    dw `33333333
    dw `33000033
    dw `30030033
    dw `30330033
    dw `30330033
    dw `30000003
    dw `33330033
    dw `33333333
    ; 5
    dw `33333333
    dw `30000033
    dw `30033333
    dw `30000033
    dw `33330003
    dw `30330003
    dw `33000033
    dw `33333333
    ; 6
    dw `33333333
    dw `33000033
    dw `30033333
    dw `30000033
    dw `30033003
    dw `30033003
    dw `33000033
    dw `33333333
    ; 7
    dw `33333333
    dw `30000003
    dw `33333003
    dw `33330033
    dw `33300333
    dw `33000333
    dw `33000333
    dw `33333333
    ; 8
    dw `33333333
    dw `33000033
    dw `30333003
    dw `33000033
    dw `30333003
    dw `30333003
    dw `33000033
    dw `33333333
    ; 9
    dw `33333333
    dw `33000033
    dw `30330003
    dw `30330003
    dw `33000003
    dw `33330003
    dw `33000033
    dw `33333333
TilesEnd:

Tilemap:
    db $00, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $02, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $1A, $1A, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $0A, $0B, $0C, $0D, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $0E, $0F, $10, $11, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $12, $13, $14, $15, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $16, $17, $18, $19, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $09, $09, $09, $09, $09, $09, $09, $09, $09, $09, $09, $09, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
TilemapEnd:

Player:
    dw `00000000
    dw `30300303
    dw `03000030
    dw `00333300
    dw `03133130
    dw `33133133
    dw `33333333
    dw `30000003
Player2:
    dw `00000000
    dw `03000030
    dw `03000030
    dw `00333300
    dw `03233230
    dw `33233233
    dw `33333333
    dw `03000030
PlayerEnd:
    
SECTION "Counter", HRAM
wFrameCounter: db

SECTION "Input Variables", WRAM0
wCurKeys: db
wNewKeys: db
