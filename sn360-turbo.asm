;   Original SN-360 firmware by Slawomir Nienaltowski (Atari Studio) 1992
;   This firmware by: Michal Szwaczko (WireLabs) 1997,1998,2006-2009
;   Reverse-engineered from bare metal, cracked, fixed and enhanced

;   Some comments or code annotations may be completely wrong, since they come 
;   from original disassembly back from the 1998-1999 when I had no idea of the real 
;   workings of 8051 and FDCs :))) 
;   Also, this is not a complete rewrite of the original Nienaltowski's code
;   just a reverse + hacks. Still, pity they hadn't done same in 1990's :)
;
;   Thanks to drac030, seban, trub
;   Fucks to: gRzEnIu, kaz
;
;   Drive Memory map
;
;   0x0000-0x0003 - 2797 Registers (status/command, track, sector, data)
;   0x8000-0x80FF - internal drive buffer, data from drive/sectors
;   0x8100-0x81FF - external buffer , anything read from atari
;
;   Fixes:
;
;   - fixed '80 tracks in PERCOM' bug, for 360k 5.25 drives
;   - fixed '0xFF byte formatting' bug for DD/DSDD
;   - some code cleanups, optimizations, and code-flow clarifications
;
;   New features:
;
;   - support for US DOUBLER compatible ultra speed (57kbaud,$08) 
;   - ultraspeed sector skew, and FORMAT_CUSTOM command for SDX
;
;   TODO:
;
;   - support for 3.5 720k drives in both 9/512 and 18/256 track formats
;   - make format_custom really set up sector skew, now it's just faking it :)
;   - format real SD (just for a laugh)
;   - romdisk?
;
;   $Id: sn360.asm,v 0.11 2007/06/25 17:41:53 mikey Exp $
;

; R0-R4 bank0
.equ R0_B0,             0x00            ;_CurTrk, 0
.equ R1_B0,             0x01            ;_WantTrk, 1
.equ R2_B0,             0x02            ;SecOnTrk, 2
.equ R3_B0,             0x03            ;LSBsec, 3
.equ R4_B0,             0x04            ;MSBsec, 4

; R0-R4 bank1 
.equ R0_B1,             0x08            ; varCurTrk_bank1, 8
.equ R1_B1,             0x09            ; varTrkNo_bank1, 9
.equ R2_B1,             0x0a            ; varSecNo_bank1, 0Ah

; variables
.equ custom,            0x6e
.equ turboflag,         0x6f


.equ trk_nr,            0x70
.equ notconfigured,     0x71
.equ licznik,           0x72
.equ varWDStatus,       0x73

.equ DAUX2,             0x74
.equ DAUX1,             0x75
.equ CMD,               0x76

.equ Flag_SIDES,        0x77
.equ Flag_SEKTORS,      0x78
.equ Flag_ENHANCED,     0x79
.equ Flag_FM,           0x7A

.equ StatusFlag,        0x7C
.equ Status,            0x7D

.equ drive_number,      0x7E
.equ WhichFormat,       0x7F

; btw, as31 .equ syntax sux!


                      .org 0x0000

; usual 8051 coldstart vector crap :)
; look ma, no interrupts :)

start:                ljmp power_on
                      .org 0x0003
                      reti
                      .org 0x000B
                      reti
                      .org 0x0013
                      reti
                      .org 0x001B
                      reti
                      .org 0x0023
                      reti
                      .org 0x002B
                      reti
                      .org 0x0033 
                      reti

                      .org 0x0040

; the real start 
power_on:             clr EA                      ; disable interrupts

                      setb IT0                    ; falling edge (1->0 transition) interrupts
                      setb IE0                    ; enable reading T0 (COMMAND)
                      mov SP, #0x0f               ; stack @ 0x0F

                      clr RS0                     ; Register bank 0
                      clr RS1

                      mov StatusFlag, #0
                      lcall init_uart

                      mov R0, #0                  ; cur trk
                      mov R1, #0                  ; want trak

                      clr P1.0                    ; MOTOR ON

                      mov notconfigured, #1
                      lcall bzium

                      setb P1.0                   ; MOTOR OFF

                      mov trk_nr, #0
                      lcall drive_init

main:                 mov notconfigured, #1
waitforcmd:           setb P1.4                   ; ten pin idzie do 74LS123, wlacza puls dla IDX z drugiej strony flopa
                      lcall cmd_handler           ; glowne wejscie do obslugi SIO
                      mov A, CMD
                      cjne A, #4Fh, main
                      sjmp waitforcmd

; =========================================================================================================

cmd_handler:          lcall read_sio_frame        ; this reads sio frame and returns with
                      mov CMD, A                  ; A=CMD,R3=DAUX1,R4=DAUX2, or A=0 on fail
                      mov DAUX1, R3               ; lsb sectorno
                      mov DAUX2, R4               ; msb sectorno

; common commands

                      cjne A, #0x66, *+6          ; CUSTOM_FORMAT $66
                      ljmp custom_format

                      cjne A, #0x3f, *+6          ; POLL $3F
                      ljmp send_pokey_byte

                      cjne A, #22h, *+6
                      ljmp FormatMedium           ; FORMAT MEDIUM

                      cjne A, #50h, *+6
                      ljmp PutSectorEntry         ; PUT SECTOR

                      cjne A, #52h, *+6
                      ljmp ReadSector             ; GET SECTOR

                      cjne A, #53h, *+6
                      ljmp SendStatus             ; GET STATUS

                      cjne A, #57h, *+6
                      ljmp WriteVerifySect        ; PUT SECTOR+VERIFY

                      cjne A, #21h, *+6
                      ljmp Format                 ; FORMAT VIA PERCOM

                      cjne A, #0, *+4             ; crc error or not this drive
                      ret                         ; so bail out

                      cjne A, #4Eh, *+6
                      ljmp SendPERCOM             ; GET CONFIG (PERCOM)

                      cjne A, #4Fh, *+6
                      ljmp ConfigDrive            ; PUT CONFIG (PERCOM)

                      orl Status, #1              ; command not recognized
                      lcall Send_NAK              ; Send NAK, finish.
                      ret 

; main format dispatcher

Format:               mov notconfigured, #0
                      clr IE0                     ; disable reaction on COMMAND line state

                      mov A, WhichFormat          ; WhichFormat is set by set_percom(); Possible binary values: 00-SD,01-ED,10-DD,11-DSDD,
                                                  ; so, if bit0 = 1 we are in DD, if bit0 = 0 we are in SD/ED
                      cjne A, #0, *+6             ; SD
                      ljmp FormatMedium           ; (ORIGINAL BUG) NO REAL SD, drive formats ED anyways.

                      cjne A, #1, *+6             ; ED
                      ljmp FormatMedium

                      cjne A, #2, *+6             ; DD
                      ljmp Format_DD

                      cjne A, #3, *+6             ; DSDD
                      ljmp Format_DSDD

                      ljmp FormatMedium           ; default density
                      ret

; format medium density (ED)

FormatMedium:         mov notconfigured, #0
                      clr IE0                     ; disable reaction on COMMAND line state 

                      lcall SetWD_SSED            ; set ED (medium)
                      lcall Send_ACK

                      mov R1, #0                  ; trk 0
                      mov R0, #0                  ; side 0
                      mov B, #40                  ; 40 tracks

l1:                   push B
                      lcall prepare_track_ED      ; prepare trk in memory
                      lcall sub_00010B8E          ; phys write trk
                      cjne A, #0, fail1
                      lcall verify_track_ED       ; returns A!=0 if error 
                      cjne A, #0, fail1
                      pop B
                      inc R1
                      djnz B, l1                  ; track in B

done_format:          lcall Send_COMPLETE
                      lcall Wait
                      mov B, #0

                      mov R5, #80h
                      mov A, WhichFormat          ; $80 or $100 bytes per sector
                      jnb ACC.1, *+5              ; skip nxt line
                      mov R5, #0

                      mov A, #0xff                ; $100 bytes per sector
                      lcall serout
                      djnz R5, *-5                ; possible bug, send $80/$100 FFs and finish formatting
                                                  ; but this should send bad sectors list too.
                      mov A, B                    ; cksum
                      lcall serout
                      ret


fail1:                pop B
                      lcall Wait
                      lcall Send_ERR
                      mov B, #0

                      mov A, #0                   ; send two $00 bytes
                      lcall serout
                      mov A, #0
                      lcall serout

                      mov R5, #7Eh                ; and $7E $FF bytes

                      mov A, #0xff
                      lcall serout
                      djnz R5, *-5
                      mov A, B                    ; cksum
                      lcall serout
                      ret

; format double density (DD)

Format_DD:            lcall Send_ACK
                      mov R1, #0                  ; track number
                      mov R0, #0                  ; side number
                      mov B, #40                  ; 40trk

l2:                   push B

                      lcall prepare_track_DD      ; prepare trk in memory (mfm data, skew etc)
                      lcall sub_00010B8E          ; physically write trk

                      cjne A, #0, fail2
                      lcall verify_track_DD       ; sprawdzanie poprawnosci ?
                      cjne A, #0, fail2
                      pop B
                      inc R1
                      djnz B, l2
                      sjmp done_format


fail2:                pop B
                      lcall Send_ERR
                      lcall Wait
                      mov B, #0
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov R5, #0FEh

                      mov A, #0xff
                      lcall serout
                      djnz R5, *-5
                      mov A, B                   ; crc
                      lcall serout
                      ret

; format double side double density (DSDD)

Format_DSDD:          lcall Send_ACK
                      mov R1, #0                 ; trk
                      mov B, #40                 ; format 40trk

l3:                   push B

                      mov R0, #0                  ; side nr
                      lcall prepare_track_DD
                      lcall sub_00010B8E
                      cjne A, #0, fail2
                      lcall verify_track_DD
                      cjne A, #0, fail2

                      mov R0, #1                  ; side nr
                      lcall prepare_track_DD_side1   ; _trk_DD_side1         ;sub_00010C23
                      lcall sub_00010B8E
                      cjne A, #0, fail2
                      lcall verify_track_DD_side1
                      cjne A, #0, fail2

                      pop B
                      inc R1
                      djnz B, l3

                      ajmp done_format            ; ret


; ===============================================================================
; <- and here was a dotted line but PacMan ate it ->


WriteVerifySect:      lcall putsec      ;sub_00010228
                      cjne A, #0, return
                      lcall wait_wd_ready
                      mov R5, #0
                      mov A, R2
                      lcall write_sec_register

                      mov A, R0
                      rl A
                      orl A, R5
                      anl A, #110b
                      orl A, #10001000b
                      lcall write_cmd_register
                      lcall WaitShort

                      mov DPTR, #8100h
                      lcall sub_00010AAB
                      cjne A, #0, err ;loc_0001021C

                      push R0_B0
                      mov DPTR, #8000h
                      mov R7, DPH
                      mov R0, DPL
                      mov R6, #80h

                      lcall chkboot ; bootsector?
                      jnb ACC.1, wf ; do it do_it ;loc_00010204

                      mov R6, #0
wf:                   mov DPTR,#8100h

compare:              movx A, @DPTR ; wez z jednego bufora
                      mov B, A      ; przechowaj w B
                      mov P2, R7    ; ustaw drugi bufor (sprytne! - w P2 jest teraz DPH, a w R0 DPL, czyli @R0 = @DPTR na inny bufor)
                      movx A, @R0     ; przechowaj w A
                      cjne A, B, exi  ;loc_0001021A ; porownaj bajty
                      inc R0
                      inc DPTR
                      djnz R6, compare  ;loc_00010207
                      pop R0_B0
                      lcall Send_COMPLETE

return:               ret 

exi:                  pop R0_B0
err:                  sjmp chksumerror

;

PutSectorEntry:       lcall putsec              ;sub_00010228
                      cjne A, #0, *+6           ;ret 
                      ljmp Send_COMPLETE
                      ret 

putsec:               push B
                      lcall Send_ACK
                      lcall sub_0001053B
                      pop B
                      lcall GetLocation

                      clr RI
                      mov DPTR,#8000h
                      mov R5, #80h
                      lcall chkboot
                      jnb ACC.1, ps1 ;loc_00010244
                      mov R5, #0

ps1:                   mov B, #0
ps2:                   jnb T0, chksumerror
ps3:                   jnb RI, ps2 ; loc_00010247 
                      mov A, SBUF
                      clr RI
                      movx @DPTR, A
                      inc DPTR
                      add A, B
                      jnc ps4 ;loc_00010258
                      inc A

ps4:                  mov B, A
                      djnz R5, ps3 ;loc_0001024A

ps5:                  jnb T0, chksumerror
                      jnb RI, ps5 ;loc_0001025C
                      mov A, SBUF
                      clr RI
                      cjne A, B, chksumerror
                      lcall wait96
                      lcall Send_ACK
                      lcall sub_00010AF5
                      cjne A, #0, chksumerror
                      ret 


chksumerror:          lcall Wait
                      lcall Send_ERR
                      mov A, #0xff
                      ret 


ReadSector:           push B
                      lcall WaitShort
                      lcall Send_ACK
                      lcall sub_0001053B        ; uruchom flopa
                      pop B
                      lcall GetLocation
                      lcall sub_00010A69        ; find sector
                      push ACC
                      cjne A, #0, read_error
                      lcall Send_COMPLETE
                      sjmp SendSector

read_error:           lcall Send_ERR

; sector in the buffer, pump it to the atari 

SendSector:           lcall wait96
                      mov B, #0
                      mov DPTR,#8000h             ; point to buffer
;
                      mov R5, #80h
                      lcall chkboot          ; check if this is sector 1-3 on side0 trk0 
                      jnb ACC.1, Xfer             ; thus if 0x80 or 0x100 bytes to transfer 
                      mov R5, #0
Xfer:                 lcall seroutmem
                      djnz R5, Xfer
                      mov A, B                    ; nadaj czeksume
                      lcall serout
                      pop ACC
                      ret 


chkboot:              mov A, R2
                      anl A, #11111100b           ; check two lowest bits
                      cjne A, #0, _s              ; sector > 3
                      cjne R1, #0, _s             ; wanttrk > 0
                      cjne R0, #0, _s             ; currtrk > 0
;
                      mov A, #0                   ; yes, a bootsector
                      ret 

_s:                   mov A, WhichFormat          ; not bootsectors, so sectorsize is density dependent
                      ret 


SendStatus:           lcall WaitShort
                      lcall Send_ACK
                      lcall WaitShort
                      lcall Send_COMPLETE
                      lcall WaitShort
                      jnb IE0, sendit_         ; wait for command line 

                      lcall SetWD_SSED            ; bug? this does not fit here

sendit_:              mov B, #0
                      mov A, varWDStatus
                      mov C, ACC.6                ; check write protect?
                      mov A, Status
                      mov ACC.3, C                ; copy to bit 3 of status[1]
                      orl A, #10000b              ; set bit4 (motor on) if applicable
                      anl A, #11111001b           ; clear bits 1 and 2 = operation successful
                      lcall serout                ; send status[0] 
;
                      lcall read_stat_register         ; get WD status
                      xrl A, #0xff                ; invert all bits
                      lcall serout                ; send status[1]
;
                      mov A, #0E0h                ; (ORIGINAL BUG) very long timeout - about 3 minutes.
                      lcall serout                ; send status[2] - timeout value
;
                      mov A, #0
                      lcall serout                ; send status[3] - not used
;
                      mov A, B
                      lcall serout                ; chksum
;
                      anl Status, #0F0h           ; clear upper half of status byte.
                      mov StatusFlag, #0
                      ret 

; read and set percom. data from sio goes to $8000 and the drive parameters 
; are set (some are ignored though)

custom_format:        mov notconfigured, #0
                      mov custom, #1
                      lcall Send_ACK
                      mov R3, #0x81 ; 0x80 bytes + crc
                      sjmp cd
                      
ConfigDrive:          mov custom, #0
                      mov notconfigured, #0
;
                      lcall Send_ACK
;
                      mov R3, #13  ; 12 bytes + crc
cd:                   mov B, #0
                      mov DPTR,#8000h             ; ptr to read buffer
                      clr RI

; sync for read (command line low) 
sync_:                jb T0, _receive_it
                      ljmp PERCOMFailed

_receive_it:
                      jnb RI, sync_
                      mov A, SBUF
                      clr RI
                      movx @DPTR, A
                      inc DPTR
;                      inc R3

                      djnz R3,  _dalej        ; already 13 bytes?
                      sjmp _juzcaly

_dalej:               add A, B
                      jnc _chksum
                      inc A

_chksum:              mov B, A
_juzcaly:             cjne R3, #0, _receive_it   ; czytaj dalej
                      cjne A, B, _failpercom      ; sprawdz sume

; OK, Percom block in memory, now we need to set it to the drive

                      ljmp SetDriveParams
_failpercom:          ljmp PERCOMFailed

SetDriveParams:       mov DPTR,#8000h
; this part is tricky ;)
                      mov Flag_FM, #0
                      mov Flag_ENHANCED, #0
                      mov Flag_SEKTORS,	#0
                      mov Flag_SIDES, #0

                      movx A, @DPTR               ; percom[0],8000, traks
                      cjne A, #40, skip0
;
                      inc Flag_FM                 ; 40 trks
                      inc Flag_ENHANCED           ; +1 +1 +1 +1
                      inc Flag_SEKTORS
                      inc Flag_SIDES

skip0:                inc DPTR
                      inc DPTR
                      inc DPTR
                      movx A, @DPTR               ; percom[3],8003, lsb	of sec/trk
                      cjne A, #18, skip1          ; if 18/trk  ; +1 +1 +0 +1

                      inc Flag_FM
                      inc Flag_SEKTORS            ; sets 02 02 01 02 if 18 sec/trk
                      inc Flag_SIDES

skip1:                cjne A, #26, skip2
                      inc Flag_ENHANCED           ; jesli 26/trk  +0 +0 +1 +0

skip2:                inc DPTR                    ; percom[4] sides-1
                      movx A, @DPTR
                      cjne A, #0, skip3           ; single side
                      inc Flag_FM                 ; +0 +1 +1 +1
                      inc Flag_ENHANCED
                      inc Flag_SEKTORS

skip3:                cjne A, #1, skip4           ; double sides
                      inc Flag_SIDES              ; +1 +0 +0 +0

skip4:                inc DPTR                    ; percom[5]
                      movx A, @DPTR
                      jb ACC.2, skip5             ; MFM/FM
                      inc Flag_FM                 ; +0 +0 +0 +1

skip5:                jnb ACC.2, skip6
                      inc Flag_ENHANCED           ; +1 +1 +1 +0
                      inc Flag_SEKTORS
                      inc Flag_SIDES

skip6:                inc DPTR                    ; percom[6]
                      movx A, @DPTR               ; MSB	of sectorsize
                      cjne A, #0, skip7           ; +0 +0 +1 +1
                      inc Flag_FM
                      inc Flag_ENHANCED

skip7:                cjne A, #1, skip8
                      inc Flag_SEKTORS
                      inc Flag_SIDES              ; +1 +1 +0 +0

skip8:                inc DPTR                    ; percom[7] lsb of sectorsize
                      movx A, @DPTR
                      cjne A, #80h, skip9
                      inc Flag_FM                 ; +0 +0 +1 +1
                      inc Flag_ENHANCED

skip9:                cjne A, #0, check_params
                      inc Flag_SEKTORS            ; +1 +1 +0 +0
                      inc Flag_SIDES

; now check if the percom parameters were valid, and set the WD
; so that it represents them to the drive. The check is tricky -
; if no flag reached 6 this means that percom was invalid, we send NAK etc.
; if there is a 6 in one of the flags, this means that the corresponding
; functionality was legal and we jump to the real part that sets it in the 
; WD controller.

check_params:         mov A, Flag_FM
                      cjne A, #6, skip11
                      lcall SetWD_SSSD
                      ljmp epilog_percom

skip11:               mov A, Flag_ENHANCED
                      cjne A, #6, skip12
                      lcall SetWD_SSED
                      ljmp epilog_percom

skip12:               mov A, Flag_SEKTORS
                      cjne A, #6, skip13
                      lcall SetWD_SSDD
                      ljmp epilog_percom

skip13:               mov A, Flag_SIDES
                      cjne A, #6, PERCOMFailed
                      lcall SetWD_DSDD

; finish setting percom, reset status, send ACK etc

epilog_percom:        mov A, custom
                      cjne A,#0, custt

                      lcall WaitShort
                      lcall Send_ACK
                      lcall WaitShort
                      lcall Send_COMPLETE
                      mov StatusFlag, #0
                      ret 

PERCOMFailed:         lcall WaitShort
                      lcall Send_ERR
                      mov StatusFlag, #0xff
                      ret 

custt:                lcall WaitShort 
                      ljmp Format


SendPERCOM:           lcall Send_ACK
                      lcall WaitShort
                      lcall Send_COMPLETE
                      lcall WaitShort
                      jnb IE0, Sendit
                      lcall SetWD_SSED

Sendit:               mov A, WhichFormat
                      cjne A, #0, SendPercomED
                      mov B, #0
; send SD percom
                      mov A, #40
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #18
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #128
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout

                      mov A, B
                      lcall serout
                      mov StatusFlag, #0
                      ret 

SendPercomED:         cjne A, #1, SendPercomDD
                      mov B, #0
;
                      mov A, #40
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #26
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #100b  ; MFM
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #80h
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout

                      mov A, B
                      lcall serout
                      mov StatusFlag, #0
                      ret 

SendPercomDD:         cjne A, #2, SendPercomDSDD
                      mov B, #0
;
                      mov A, #40
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #18
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #4  ; MFM
                      lcall serout
                      mov A, #1
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout

                      mov A, B
                      lcall serout
                      mov StatusFlag, #0
                      ret 

SendPercomDSDD:       mov B, #0
                      mov A, #40   ;(ORIGINAL BUG) should be 40
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #18
                      lcall serout
                      mov A, #1     ; (ORIGINAL BUG)  DSDD has 2 heads, shoul be 1
                      lcall serout
                      mov A, #100b  ; MFM
                      lcall serout
                      mov A, #1
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout
                      mov A, #0
                      lcall serout

                      mov A, B
                      lcall serout
                      mov StatusFlag, #0
                      ret 


sub_0001053B:         lcall wait_wd_ready
                      jnb IE0, __retu
                      lcall dioda_i_krec
                      cjne A, #0, __retu
                      clr IE0
                      clr IE0
__retu:               ret 


SetWD_SSED:           mov WhichFormat, #1
                      clr P1.1            ; /DDEN = 0 = MFM , double density ( ED?)

                      setb P1.2  ; these two bits look unconnected, oddly from the code it seems that
                      setb P1.3  ; they are 01 or 10 depending on whether SSDD or DSDD respectively

                      mov Status, #80h ; set status bit7 = ED
                      ret 

SetWD_SSSD:           mov WhichFormat, #0
                      setb P1.1  ; /DDEN = 1 = FM, singledensity
                      setb P1.2
                      setb P1.3
                      mov Status, #0  ; reset status
                      ret 

SetWD_SSDD:           mov WhichFormat, #2
                      clr P1.1                    ; /DDEN =0
                      clr P1.2
                      setb P1.3
                      mov Status, #100000b        ;  256 bytes sectors
                      ret 

SetWD_DSDD:           mov WhichFormat, #3
                      clr P1.1                    ; /DDEN=0
                      setb P1.2
                      clr P1.3
                      mov Status, #100000b        ; sektory 256bajt
                      ret 


dioda_i_krec:         clr P1.5                    ; P1.5 connected to 10 pin of 74123 
                      push R0_B0              ; push R0
                      push R1_B0             ; push R1
                      push R2_B0            ; push R2
                      push R3_B0              ; push R3
                      push R4_B0              ; push R4
                      lcall sub_0001059C
                      pop R4_B0
                      pop R3_B0
                      pop R2_B0
                      pop R1_B0
                      pop R0_B0
                      setb P1.5
                      ret 

; rozpoznanie gestosci
sub_0001059C:         mov A, notconfigured
                      cjne A, #0, loc_000105B4    ; jmp if drive not already configured, else return
                      ret

loc_000105A2:         acall SetWD_SSSD
                      push R0_B0
                      mov R0, #0
                      lcall seek
                      lcall sub_000105DF
                      pop R0_B0
                      cjne A, #0, SetWD_SSED
                      ret 

loc_000105B4:         acall SetWD_SSED
                      push R0_B0
                      mov R0, #0
                      lcall sub_000105DF
                      pop R0_B0
                      cjne A, #0, loc_000105A2

                      mov DPTR,#8103h
                      movx A, @DPTR

                      cjne A, #1, loc_000105DC
                      push R0_B0
                      mov R0, #1
                      lcall sub_000105DF
                      pop R0_B0
                      cjne A, #0, loc_000105DA
                      acall SetWD_DSDD
                      ljmp loc_000105DC

loc_000105DA:         acall SetWD_SSDD
loc_000105DC:         mov A, #0
                      ret 


sub_000105DF:         lcall czygotowa
                      lcall read_stat_register
                      jb ACC.7,_retuuu            ; jump if drive not ready (status=10000000)
                      mov R5, #0
                      lcall read_trk_register
                      cjne A, R1_B0, loc_00010606

loc_000105F0:         mov A, R0                   ; current track
                      anl A, #1
                      rl A
                      orl A, R5
                      anl A, #6
                      orl A, #0C0h
                      lcall write_cmd_register
                      lcall WaitShort
                      lcall sub_0001060D
                      mov StatusFlag, #0
_retuuu:              ret 

loc_00010606:         lcall seek
                      mov R5, #4
                      sjmp loc_000105F0



sub_0001060D:         mov DPTR,#8100h
                      clr EA
                      mov R3, #0
                      mov R4, #0
                      push R0_B0
                      push R1_B0
                      mov R0, #0
                      mov R1, #3
                      mov P2, #0
                      mov R5, #0
                      mov R6, #40h
                      mov R7, #2

_petladluga:          movx A, @R0                 ; = movx A,0 (cmd?)
                      jb ACC.7,	loc_00010648
                      cjne A, #1, loc_00010636
                      djnz R5, _petladluga
                      djnz R6, _petladluga
                      djnz R7, _petladluga
                      sjmp loc_00010658

loc_00010636:         jnb ACC.1, loc_00010645
                      mov B, A
                      movx A, @R1                 ; =movx A,3 (data)
                      movx @DPTR, A
                      inc DPTR
                      inc R3
                      cjne R3, #0, loc_00010643
                      inc R4

loc_00010643:         mov A, B

loc_00010645:         jb ACC.0,_petladluga

loc_00010648:         pop R1_B0
                      pop R0_B0
                      setb EA
                      anl Status, #0F0h
                      cjne A, #0, loc_0001065C          ; crc error
                      mov StatusFlag, #0
                      ret 

loc_00010658:         mov A, #0xff
                      sjmp loc_00010648

loc_0001065C:         orl Status, #10b                    ; crc error
                      mov StatusFlag, A
                      ret 


return4:              ret                                ; bug :) one byte to save 


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; this actually is track verify by finding the sector. if you cant find a sector on the track that you just
; wrote, there must be something wrong.

verify_track_ED:      mov R2, #12
                      lcall sub_00010A69

                      cjne A, #0, return4
                      mov R2, #21
                      lcall sub_00010A69
                      cjne A, #0, return4
                      mov R2, #8
                      lcall sub_00010A69
                      cjne A, #0, return4
                      mov R2, #17
                      lcall sub_00010A69
                      cjne A, #0, return4
                      mov R2, #26
                      lcall sub_00010A69
                      cjne A, #0, return4
                      mov R2, #4
                      lcall sub_00010A69
                      cjne A, #0, return4
                      mov R2, #13
                      lcall sub_00010A69
                      cjne A, #0, return4
                      mov R2, #22
                      lcall sub_00010A69
                      cjne A, #0, return4
                      mov R2, #9
                      lcall sub_00010A69
                      cjne A, #0, return4
                      mov R2, #18
                      lcall sub_00010A69
                      cjne A, #0, return4
                      mov R2, #5
                      lcall sub_00010A69
                      cjne A, #0, return4
                      mov R2, #14
                      lcall sub_00010A69
                      cjne A, #0, return4
                      mov R2, #23
                      lcall sub_00010A69
                      cjne A, #0, return4

                      mov R2, #1
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #10
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #19
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #6
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #15
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #24
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #2
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #11
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #20
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #7
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #16
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #25
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #3
                      lcall sub_00010A69
                      cjne A, #0, return3
return3:              ret 


verify_track_DD:      mov R2, #5
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #16
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #8
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #11
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #3
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #14
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #6
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #17
                      lcall sub_00010A69
                      cjne A, #0, return3
                      mov R2, #9
                      lcall sub_00010A69
                      cjne A, #0, return3

                      mov R2, #1
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #12
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #4
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #15
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #7
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #18
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #10
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #2
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #13
                      lcall sub_00010A69
                      cjne A, #0, _return
_return:              ret 

verify_track_DD_side1:  mov R2, #13
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #2
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #10
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #18
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #7 
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #15
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #4
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #12
                      lcall sub_00010A69
                      cjne A, #0, _return

                      mov R2, #1
                      lcall sub_00010A69
                      cjne A, #0, _return
                      mov R2, #9 
                      lcall sub_00010A69
                      cjne A, #0, return2
                      mov R2, #17
                      lcall sub_00010A69
                      cjne A, #0, return2
                      mov R2, #6
                      lcall sub_00010A69
                      cjne A, #0, return2
                      mov R2, #14
                      lcall sub_00010A69
                      cjne A, #0, return2
                      mov R2, #3
                      lcall sub_00010A69
                      cjne A, #0, return2
                      mov R2, #11
                      lcall sub_00010A69
                      cjne A, #0, return2
                      mov R2, #8
                      lcall sub_00010A69
                      cjne A, #0, return2
                      mov R2, #16
                      lcall sub_00010A69
                      cjne A, #0, return2
                      mov R2, #5
                      lcall sub_00010A69
                      cjne A, #0, return2
return2:              ret 

; find sector ( przeksztalcenie z nr sektora na numer sciezki + sector na scieze)

GetLocation:          mov A, WhichFormat
                      cjne A, #1, GetAddress_18se
                      lcall GetAddress_26se
                      ret 

GetAddress_26se:      push B
                      cjne R3, #0, ga1            ; lsbsecno >0
                      mov R1, #0                  ; trk
                      mov R2, #0                  ; secontrk
                      sjmp ga2                    ; lsbsecno = 0
;lsbsec > 0
ga1:                  mov A, R3                   ; lsb	sector
                      dec A                       ; correction for sectors numbering from 1 not 0 
                      mov B, #26                  ; 26 trackks
                      div AB                      ; divide sec number by number of tracks 
                      mov R1, A                   ; and you get trk numb in A
                      inc B
                      mov R2, B                   ; and sector number relative to track in B 
; lsbsec=0
ga2:                  cjne R4, #0, ga3            ; msbsecno > 0
                      sjmp ga4                    ; msbsecno = 0

ga3:                  mov A, R4
;msbsecno > 0
                      dec A
                      mov B, #10
                      mul AB
                      add A, #9
                      add A, R1
                      mov R1, A
                      mov A, R4
                      rl A
                      rl A
                      mov B, A
                      mov A, R2
                      add A, #26
                      clr C
                      subb A, B
                      mov R2, A
;msbsecno = 0

ga4:                  clr C
                      mov A, R2
                      subb A, #27
                      jc ga5
                      inc A
                      mov R2, A
                      inc R1

ga5:                  pop B
                      mov R0, #0
                      lcall check_trk_legal
                      ret 


; check if seek parameter is legal, i.e if seek track is 
; between 0 and 39.

check_trk_legal:      mov A, R1                   ; target track in R1 
                      cjne A, #40,*+3  ; _c             ; if < 40 do nothing
                      jnc set_001      ; _c
                      ret 

set_001:              mov R0, #0                  ; cur	0
                      mov R1, #0                  ; trk	0
                      mov R2, #1                  ; sec	1
                      ret 

; get_addres 

GetAddress_18se:      push R3_B0
                      push R4_B0
                      dec R3
                      cjne R3, #0xff, ga6
                      dec R4

ga6:                  mov A, R4
                      mov B, #0Eh
                      mul AB
                      mov R1, A
                      mov A, R4
                      rl A
                      rl A
                      mov B, #12h
                      div AB
                      add A, R1
                      mov R1, A
                      inc B
                      mov R2, B
                      mov A, R3
                      mov B, #12h
                      div AB
                      add A, R1
                      mov R1, A
                      mov A, B
                      add A, R2
                      cjne A, #13h, ga7

ga7:                  jc ga8
                      clr C
                      subb A, #12h
                      inc R1
ga8:                  mov R2, A
                      mov R0, #0
                      mov A, WhichFormat
                      cjne A, #3, ga10
                      mov A, R1
                      cjne A, #28h, ga9 

ga9:                  jc ga10 
                      mov R0, #1
                      mov A, #4Fh
                      clr C
                      subb A, R1
                      mov R1, A
                      mov A, #13h
                      clr C
                      subb A, R2
                      mov R2, A

ga10:                 pop R4_B0
                      pop R3_B0
                      acall check_trk_legal
                      ret 


drive_init:           mov C, P1.0                 ; motor state to C

mo:                   clr P1.0                    ; MOTOR ON
                      mov R2_B1, #1
                      mov R1_B1, #0
                      mov R0_B1, #0
                      jnc _ret                    ; if motor was on, return 
                      lcall SeekToCurrent         ; reposition at current track  and wait for driveready
                      mov A, trk_nr
                      lcall write_trk_register
_ret:                 ret 

                      clr C                       ; this is unused, looks like forcing motor on all the time 
                      sjmp mo

;;;;;;;;;;;;;;;;;;;;

sub_0001091A:         setb RS0 ; bank1 
                      cjne R2, #0, loc_00010921
                      sjmp set_bank0

loc_00010921:         dec R0
                      cjne R0, #0, set_bank0
                      dec R1
                      cjne R1, #0, set_bank0
                      dec R2
                      cjne R2, #0, set_bank0

                      lcall read_trk_register
                      mov trk_nr, A
                      setb P1.0

set_bank0:            clr RS0
                      ret




SeekToCurrent:        push ACC
                      push R1_B0
;
                      lcall read_trk_register          ; get current track 
                      mov R1, A                   ; trk -> R1
                      lcall seek             ; in R1 trk nmbr
;
                      mov R6, #0                  ; wait loop 
                      mov R7, #0

WaitREADY:            lcall read_stat_register
                      jnb ACC.7, DriveREADY
                      djnz R6, WaitREADY
                      djnz R7, WaitREADY

DriveREADY:           pop R1_B0
                      pop ACC
                      ret 

; seek to track 0
loc_00010955:         mov R1, #0
                      mov R5, #0
                      lcall seek

loc_0001095C:         lcall read_trk_register
                      cjne A, #0, loc_00010955
                      lcall dioda_i_krec
                      cjne A, #0, read_sio_frame
                      clr IE0


read_sio_frame:       mov R1, #40h
                      mov R0, #0

petl:                 acall sub_0001091A          ; this checks if disk changed (?)

                      jnb T0, READYTORECEIVE      ; COMMAND low?
                      djnz R0, petl
                      djnz R1, petl
;
                      jb IE0, loc_0001095C
                      sjmp read_sio_frame


READYTORECEIVE:	      clr RI
                      mov DPTR,#8100h
                      mov R3, #0
                      mov B, #0

WaitCOMMAND:          jb T0, cksum_error

odbierz_z_sio:        jnb RI, WaitCOMMAND
                      mov A, SBUF
                      clr RI

                      movx @DPTR, A               ; frame to buffer
                      inc DPTR
                      inc R3
                      cjne R3, #5, czeksumuj      ; check if all 5 (4+crc) bytes received
                      sjmp gotframe               ; yes

czeksumuj:            add A, B
                      jnc cz0
                      inc A

cz0:                  mov B, A

gotframe:             cjne R3, #5, odbierz_z_sio
                      cjne A, B, cksum_error   ; cksum error
                      mov DPTR,#8100h
                      movx A, @DPTR


; here we check which drive is set up on the lever (D1-D2) 
; this is total abuse of the 8051 assembly since only 1 bit really changes it

                      clr C
                      subb A, #31h                ; D1 or D2 (0/1)
                      mov B, A
;
                      mov A, P1                   ; check lever
                      rr A                        ; P1.6  P1.7 (11=0,10=1)
                      rr A
                      rr A
                      rr A
                      rr A
                      rr A
                      xrl A, #11b
                      anl A, #11b
;
                      mov drive_number,A
                      mov A, B

                      cjne A, drive_number, WaitEndCOMMAND ; check if cmd for this drive 

                      mov A, B
;
                      inc DPTR
                      movx A, @DPTR
                      inc DPTR
                      push ACC                    ; sio cmnd to stack
;
                      movx A, @DPTR
                      mov R3, A                   ; daux1 to R3
                      inc DPTR
                      movx A, @DPTR
                      mov R4, A                   ; daux2 to R4
                      pop ACC                     ; sio cmd to A

waicik:               jnb T0,*                    ; Wait for SIO COMMAND line to go hi
                      ret 

WaitEndCOMMAND:       mov A, #0
                      jnb T0,*
                      ret 

cksum_error:          mov A, turboflag
                      cjne A,#0,turoff
                      lcall switch_turbo
                      mov A, #0
                      jnb T0,*
                      ret

turoff:               lcall disable_turbo
                      mov A, #0
                      jnb T0,*
                      ret

send_pokey_byte:      lcall WaitShort
                      lcall Send_ACK
                      lcall WaitShort
                      lcall Send_COMPLETE
                      lcall WaitShort

                      mov B, #0
                      mov A, #8
                      lcall serout                ; ultraspeed byte
                      mov A, B
                      lcall serout                ; chksum 
                      ret 


Send_ACK:             mov A, #41h
                      sjmp serout

Send_COMPLETE:        mov A, #43h
                      sjmp serout

Send_ERR:             mov A, #45h
                      sjmp serout

Send_NAK:             mov A, #4Eh
                      sjmp serout


; SERIAL UART STUFF

seroutmem:            movx A, @DPTR
                      inc DPTR
serout:               jnb TI, *         ;serout
                      mov SBUF,A
                      clr TI
;
                      add A, B
                      jnc cks ;returncksum  ; on the fly checksumming 
                      inc A
cks:                  mov B, A
                      ret 


switch_turbo:         clr TR1
                      mov SCON, #0x50             ; mode: 8bit UART, autoreload, clocked by timer1
                      mov TMOD,#0x20
                      mov TL1, #0xFF
                      mov TH1, #0xFF
                      mov PCON,#0x80              ; double the baudrate 
                      setb TR1                    ; start ticking

                      setb TI
                      setb RI

                      mov turboflag,#1
                      ret

disable_turbo:        clr TR1
init_uart:            mov SCON, #0x50             ; mode: 8bit UART, autoreload, clocked by timer1
                      mov TMOD,#0x20              ;
                      mov TL1, #0xFD
                      mov TH1, #0xFD              ; 9600 baud
                      mov PCON,#0x80              ; double the baudrate -> 19200 baud
                      setb TR1                    ; start ticking
                      setb TI                     ; Serial Port	Control
                      setb RI                     ; Serial Port	Control
                      mov turboflag,#0
                      ret 



seek:                 lcall wait_wd_ready             ; check if wd	is busy
                      acall check_trk_legal       ; check if current track > 40
                      mov A, R1	                  ; write desired trk to data reg
                      lcall write_data_register
                      mov A, #10h                 ; execute seek (00010000)
                      lcall write_cmd_register
                      lcall WaitShort
                      lcall wait_wd_ready
                      mov varWDStatus, A
                      ret 


; startup noise ;) after drive poweron (goto trk0, goto trk39, restore)

bzium:             mov R1, #0                   ; move to 0, then to 39
                      lcall wait_wd_ready
                      lcall Wait
                      acall seek
                      lcall Wait
                      lcall wait_wd_ready
;
                      mov R1, #39
                      lcall Wait
                      acall seek
                      lcall Wait
                      lcall wait_wd_ready
;
                      mov R5, #1Eh
;
                      mov A, #0
                      lcall write_trk_register

Restore:              mov A, #0                   ; (00000000) Restore
                      lcall write_cmd_register
                      lcall Wait
                      lcall wait_wd_ready
                      lcall read_stat_register
                      jb ACC.2,w0                 ; are we at Track 0 yet?
                      djnz R5, Restore            ; no, try $1E (30) times 

w0:                   mov R1, #0
                      lcall dioda_i_krec
                      ret 

;
; find sector
;
sub_00010A69:         mov licznik, #1

loc_00010A6C:         lcall sub_00010A81
                      cjne A, #0, loc_00010A73
                      ret 

loc_00010A73:         djnz licznik, loc_00010A6C
                      push ACC
                      lcall dioda_i_krec
                      pop ACC
                      lcall sub_00010A81
                      ret 

sub_00010A81:         lcall czygotowa
                      lcall read_stat_register
                      jb ACC.7, CRC_ERROR
                      jb IE0, CRC_ERROR
                      mov R5, #0
                      lcall read_trk_register
                      cjne A, R1_B0, loc_00010AEF

loc_00010A95:         mov A, R2
                      lcall write_sec_register
                      mov A, R0
                      anl A, #1
                      rl A
                      orl A, R5
                      anl A, #6
                      orl A, #88h
                      lcall write_cmd_register
                      lcall WaitShort
                      mov DPTR,#8000h
;
sub_00010AAB:         clr EA
                      mov R3, #0
                      mov R4, #0
                      push R0_B0
                      push R1_B0
                      mov R0, #0
                      mov R1, #3
                      mov P2, #0

loc_00010ABC:         movx A, @R0
                      jb ACC.7, loc_00010AD9
                      cjne A, #1, loc_00010AC5
                      sjmp loc_00010ABC

loc_00010AC5:         jnb ACC.1, loc_00010AD6
                      mov B, A
                      movx A, @R1
                      xrl A, #0xff
                      movx @DPTR, A
                      inc DPTR
                      inc R3
                      cjne R3, #0, loc_00010AD4
                      inc R4

loc_00010AD4:         mov A, B

loc_00010AD6:         jb ACC.0,loc_00010ABC

loc_00010AD9:         pop R1_B0
                      pop R0_B0
                      setb EA

                      anl Status, #0F0h
                      cjne A, #0, CRC_ERROR
                      mov StatusFlag, #0
                      ret 

CRC_ERROR:            orl Status, #2
                      mov StatusFlag, A
                      ret 

loc_00010AEF:         acall seek
                      mov R5, #4
                      sjmp loc_00010A95





sub_00010AF5:         mov licznik, #2
loc_00010AF8:         lcall sub_00010B0A
                      cjne A, #0, _skipek
                      ret 
_skipek:              djnz licznik, loc_00010AF8
                      push ACC
                      lcall dioda_i_krec
                      pop ACC
                      ret 

sub_00010B0A:         lcall czygotowa
                      lcall read_stat_register
                      jb ACC.7,loc_00010B73
                      jb IE0, loc_00010B73
                      lcall wait_wd_ready
                      mov R5, #0
                      lcall read_trk_register
                      cjne A, R1_B0, loc_00010B85

loc_00010B21:         mov A, R2
                      lcall write_sec_register
                      mov A, R0
                      rl A
                      orl A, R5
                      anl A, #6
                      orl A, #0A8h
                      lcall write_cmd_register
                      lcall WaitShort
                      clr EA
                      mov R3, #0
                      mov R4, #0
                      push R0_B0
                      push R1_B0
                      mov R0, #0
                      mov R1, #3
                      mov P2, #0
                      mov DPTR,#8000h

loc_00010B46:         movx A, @R0
                      jb ACC.7, loc_00010B63
                      cjne A, #1, loc_00010B4F
                      sjmp loc_00010B46

loc_00010B4F:         jnb ACC.1, loc_00010B60
                      mov B, A
                      movx A, @DPTR
                      xrl A, #0xff
                      movx @R1, A
                      inc DPTR
                      inc R3
                      cjne R3, #0, loc_00010B5E
                      inc R4

loc_00010B5E:         mov A, B

loc_00010B60:         jb ACC.0,loc_00010B46

loc_00010B63:         pop R1_B0
                      pop R0_B0
                      setb EA
                      anl Status, #0F0h
                      cjne A, #0, loc_00010B79
                      mov StatusFlag, #0
                      ret

loc_00010B73:         lcall Wait
                      anl Status, #0F0h

loc_00010B79:         orl Status, #4
                      jnb ACC.6, loc_00010B82
                      orl Status, #8

loc_00010B82:         mov StatusFlag, A
                      ret 

loc_00010B85:         acall seek
                      mov R5, #4
                      sjmp loc_00010B21


; fizyczny zapis sciezki
sub_00010B8E:         lcall czygotowa
                      lcall read_stat_register
                      jb ACC.7, drivenotready
                      lcall wait_wd_ready
                      mov R5, #4
                      lcall read_trk_register
                      cjne A, R1_B0, loc_00010C1D

loc_00010BA2:         mov A, R0
                      rl A
                      orl A, R5
                      anl A, #6
                      orl A, #0F0h
                      lcall write_cmd_register
                      lcall WaitShort

                      clr EA
                      mov R3, #0
                      mov R4, #0
                      push R0_B0
                      push R1_B0
                      mov R0, #0
                      mov R1, #3
                      mov P2, #0
                      mov DPTR,#8000h

loc_00010BC3:         movx A, @R0
                      jb ACC.7, loc_00010BEB
                      cjne A, #1, loc_00010BCC
                      sjmp loc_00010BC3

loc_00010BCC:         jnb ACC.1, loc_00010BE5
                      mov B, A
                      movx A, @DPTR
                      movx @R1, A
                      inc DPTR
                      inc R3
                      cjne R3, #0, loc_00010BDB
                      clr P1.4
                      inc R4

loc_00010BDB:         cjne R4, #18h, loc_00010BE3
                      cjne R3, #60h, loc_00010BE3
                      setb P1.4

loc_00010BE3:         mov A, B

loc_00010BE5:         jb ACC.0, loc_00010BC3
                      jb ACC.1, loc_00010BC3

loc_00010BEB:         pop R1_B0
                      pop R0_B0
                      setb EA
                      setb P1.4
                      lcall Wait
                      cjne R4, #18h, setstatus
                      cjne R3, #0, unknownstatus
                      ljmp setstatus

unknownstatus:        anl Status, #0F0h           ; zero 4 lowest bits of status 
                      cjne A, #0, nosuccess
                      mov StatusFlag, #0
                      ret 

setstatus:            mov A, #0xff                ; status=ff

drivenotready:        lcall Wait
                      anl Status, #0F0h           ; zero 4 lowest bits of status

nosuccess:            orl Status, #100b           ; set operation successful 
                      jnb ACC.6, skip0z
                      orl Status, #1000b          ; set wrprt bit if applicable 

skip0z:               mov StatusFlag, A
                      ret 

loc_00010C1D:         acall seek
                      mov R5, #4
                      ajmp loc_00010BA2


;; track preparing

prepare_track_DD_side1: mov DPTR,#8000h
                      mov R5, #80
                      mov A, #4Eh
                      lcall WriteToBuffer
                      mov R5, #12
                      mov A, #0
                      lcall WriteToBuffer
                      mov R5, #3
                      mov A, #0F6h
                      lcall WriteToBuffer
;
                      mov A, #0FCh
                      movx @DPTR, A
                      inc DPTR
;
                      mov R5, #50
                      mov A, #4Eh
                      lcall WriteToBuffer

                      mov R2, #0

traczek:              mov R5, #12
                      mov A, #0
                      lcall WriteToBuffer
                      mov R5, #3
                      mov A, #0F5h
                      lcall WriteToBuffer
                      mov A, #0FEh
                      movx @DPTR, A
                      inc DPTR
                      mov A, R1                   ;  trk nmbr
                      movx @DPTR, A
                      inc DPTR
                      mov A, R0                   ; side nr
                      movx @DPTR, A
                      inc DPTR

                      push DPL
                      push DPH

                      mov DPTR, #przeploty_dsdd
                      mov A, R2                     ; tym sterujemy ofset
                      movc A, @A+DPTR               ; bierzemy nr sektora - przeploty_ed[R2]

                      pop DPH
                      pop DPL

                      movx @DPTR, A

                      inc DPTR
                      mov A, #1
                      movx @DPTR, A
                      inc DPTR
                      mov A, #0F7h
                      movx @DPTR, A
                      inc DPTR
;
                      mov R5, #22
                      mov A, #4Eh
                      lcall WriteToBuffer
                      mov R5, #12
                      mov A, #0
                      lcall WriteToBuffer
                      mov R5, #3
                      mov A, #0F5h
                      lcall WriteToBuffer
                      mov A, #0FBh
                      movx @DPTR, A
                      inc DPTR
;
                      mov R5, #0                  ; DATA = 256 zeroes
                      mov A, #0
                      lcall WriteToBuffer
;
                      mov A, #0F7h
                      movx @DPTR, A
                      inc DPTR
                      mov R5, #20                 ; possible bug, WD datasheet says otherwise 
                      mov A, #4Eh
                      lcall WriteToBuffer
                      inc R2
                      cjne R2, #18, traczek ;loc_00010C48  ; all 18 sectors yet?
                      ljmp wrt598_4Es2
;



prepare_track_ED:     mov DPTR, #8000h  ; selected format preamble
                      mov R5, #80
                      mov A, #4Eh
                      acall WriteToBuffer
                      mov R5, #12
                      mov A, #0
                      acall WriteToBuffer
                      mov R5, #3
                      mov A, #0F6h
                      acall WriteToBuffer
                      mov A, #0FCh
                      movx @DPTR, A
                      inc DPTR
                      mov R5, #50
                      mov A, #4Eh
                      acall WriteToBuffer
;
                      mov R2, #0
;

trk_data:             mov R5, #12                 ; loop 26 times with sector data 
                      mov A, #0
                      acall WriteToBuffer
                      mov R5, #3
                      mov A, #0F5h
                      acall WriteToBuffer
                      mov A, #0FEh
                      movx @DPTR, A
                      inc DPTR

                      mov A, R1                   ; trkno
                      movx @DPTR, A
                      inc DPTR
                      mov A, R0                   ; sideno
                      movx @DPTR, A
                      inc DPTR


                      push DPL
                      push DPH

                      mov DPTR, #przeploty_ed
                      mov A, R2                     ; tym sterujemy ofset
                      movc A, @A+DPTR               ; bierzemy nr sektora - przeploty_ed[R2]

                      pop DPH
                      pop DPL

                      movx @DPTR, A
                      inc DPTR
                      mov A, #0                   ; seclen
                      movx @DPTR, A
                      inc DPTR
                      mov A, #0F7h
                      movx @DPTR, A
                      inc DPTR
                      mov R5, #22
                      mov A, #4Eh
                      acall WriteToBuffer
                      mov R5, #12
                      mov A, #0
                      acall WriteToBuffer
                      mov R5, #3
                      mov A, #0F5h
                      acall WriteToBuffer
                      mov A, #0FBh
                      movx @DPTR, A
                      inc DPTR

                      mov R5, #80h                ; 128 ff bytes //zero bytes
                      mov A, #0xff
                      acall WriteToBuffer
                      mov A, #0F7h                ; 2 CRCs
                      movx @DPTR, A
                      inc DPTR
                      mov R5, #44                 ; 44 4Es (wd docs say 54)
                      mov A, #4Eh
                      acall WriteToBuffer
;
                      inc R2
                      cjne R2, #26, trk_data    ;_skipaz	  ; all tracks yet?
                      sjmp wrt598_4Es2          ; write 598 4e and ret


prepare_track_DD:     mov DPTR, #8000h
                      mov R5, #80
                      mov A, #4Eh
                      acall WriteToBuffer
                      mov R5, #12
                      mov A, #0
                      acall WriteToBuffer
                      mov R5, #3
                      mov A, #0F6h
                      acall WriteToBuffer
                      mov A, #0FCh
                      movx @DPTR, A
                      inc DPTR
                      mov R5, #50
                      mov A, #4Eh
                      acall WriteToBuffer
                      mov R2, #0

tracz:                mov R5, #12
                      mov A, #0
                      acall WriteToBuffer
                      mov R5, #3
                      mov A, #0F5h
                      acall WriteToBuffer
                      mov A, #0FEh
                      movx @DPTR, A
                      inc DPTR
                      mov A, R1                   ; trkno
                      movx @DPTR, A
                      inc DPTR
                      mov A, R0                   ; sideno
                      movx @DPTR, A
                      inc DPTR

                      push DPL
                      push DPH

                      mov DPTR, #przeploty_dd
                      mov A, R2                     ; tym sterujemy ofset
                      movc A, @A+DPTR               ; bierzemy nr sektora - przeploty_dd[R2]

                      pop DPH
                      pop DPL


                      movx @DPTR, A
                      inc DPTR
                      mov A, #1                   ; seclen
                      movx @DPTR, A
                      inc DPTR
                      mov A, #0F7h
                      movx @DPTR, A
                      inc DPTR
                      mov R5, #22
                      mov A, #4Eh
                      acall WriteToBuffer
                      mov R5, #12
                      mov A, #0
                      acall WriteToBuffer
                      mov R5, #3
                      mov A, #0F5h
                      acall WriteToBuffer
                      mov A, #0FBh
                      movx @DPTR, A
                      inc DPTR
                      mov R5, #0
                      mov A, #0                   ; DATA, 256 zeroes
                      acall WriteToBuffer
                      mov A, #0F7h
                      movx @DPTR, A
                      inc DPTR
                      mov R5, #20                 ; 20 (54 in WD docs)
                      mov A, #4Eh
                      acall WriteToBuffer
                      inc R2
                      cjne R2, #18, tracz ;loc_00010E4C  ; all sectors yet?

wrt598_4Es2:          mov R5, #200              ; 598 4Es, let WD interrupt
                      mov A, #4Eh
                      acall WriteToBuffer
                      mov R5, #200
                      mov A, #4Eh
                      acall WriteToBuffer
                      mov R5, #198
                      mov A, #4Eh
                      acall WriteToBuffer
                      ret 

; write a byte from A to x memory pointed by DPTR,
; R5 = how many bytes
; like mov R5,#10 mov A,#1 writes 10 1s @(DPTR)

WriteToBuffer:        movx @DPTR, A
                      inc DPTR
                      djnz R5, WriteToBuffer
                      ret 

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

wait_wd_ready:        lcall read_stat_register
                      jb ACC.0, wait_wd_ready
                      ret 


czygotowa:            lcall read_stat_register
                      jnb ACC.7, DriveIsReady     ; READY?
                      push ACC
                      push R1_B0
                      lcall read_trk_register
                      mov R1, A
                      acall seek
                      acall drive_init
                      mov A, StatusFlag
                      cjne A, #10h, nie_kreci         ; check motor
                      acall bzium

nie_kreci:            acall drive_init
                      pop R1_B0
                      pop ACC

DriveIsReady:         acall drive_init
                      ret 


; 2797 register access

write_cmd_register:   mov DPTR,#0000
do_write:             movx @DPTR, A
                      ret 

write_trk_register:   mov DPTR,#0001
                      sjmp do_write

write_sec_register:   mov DPTR,#0002
                      sjmp do_write

write_data_register:  mov DPTR,#0003
                      sjmp do_write

read_stat_register:   mov DPTR, #0000
do_read:              movx A, @DPTR
                      ret 

read_trk_register:    mov DPTR, #0001
                      sjmp do_read

; timing loops 
; waitshort = circa 600us
; wait = circa 7 ms
; wait96 = circa 300us

WaitShort:            mov R7, #1
                      sjmp w2 

Wait:                 mov R7, #0Eh
w2:                   mov R6, #0

                      djnz R6, *    ;__w
                      djnz R7, *-2  ;__w
                      ret 

wait96:               mov R6, #96h
                      djnz R6, *
                      ret 

przeploty_ed:         .db 01,10,19,06,15,24,02,11,20,07,16,25,03,12,21,08,17,26,04,13,22,09,18,05,14,23 
przeploty_dd:         .db 1,12,4,15,7,18,10,2,13,5,16,8,11,3,14,6,17,9 
przeploty_dsdd:       .db 9,17,6,14,3,11,8,16,5,13,2,10,18,7,15,4,12,1 ; ???

                      .db "Fixed/enhanced by mikey/bjb"
                      .db "Thx:drac030,seban,trub "
                      .db "Fucks:grzeniu and kaz"


                      .org 0x2000
                      .end
