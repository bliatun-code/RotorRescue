# Rotor Rescue

Fly a rescue helicopter with the sticks on your FrSky X20RS. Pick up six passengers from three mountain pads and get them safely back to Base. The game runs directly on the radio as an ETHOS System tool.

**[Download Rotor Rescue 0.6.2](https://github.com/bliatun-code/RotorRescue/releases/download/v0.6.2/RotorRescue-0.6.2-X20RS.zip)** · [Norsk veiledning](docs/Kom-i-gang.md)

[![Video cover for Rotor Rescue on FrSky ETHOS. Click to watch the flight demo.](docs/images/video-cover.png)](https://www.youtube.com/watch?v=kaC_bujpgiw)

[Watch a full flight on YouTube](https://www.youtube.com/watch?v=kaC_bujpgiw)

## Install and start

1. Download the `RotorRescue-0.6.2-X20RS.zip` release asset. Leave the ZIP intact.
2. Connect the radio to FrSky Suite. Open **Lua library → Install Lua Scripts**, select the ZIP and install it.
3. Safely disconnect and restart the radio. Open **System → Rotor Rescue**. Swipe to the next System page if the tile is off screen.

For the smoothest flight, select a dedicated blank model with no heavy Lua dashboards. Disable the internal and external RF modules for that model before playing.

![The Rotor Rescue tile in the System menu on the X20RS simulator.](docs/images/system-menu.png)

## Fly the mission

- Lower the throttle fully to arm. Raise it gently to around 60% for takeoff. The amber mark at 52% shows approximate hover power with the rotor level.
- Use aileron to tilt left or right. In Mode 2, throttle is the left stick's vertical axis and aileron is the right stick's horizontal axis. Use short inputs and countersteer to slow down before landing.
- Visit **Ridge → Lookout → Camp**. Land with the skids inside the brackets and stay on each pad for 1.6 seconds. The two passengers will wait and wave if you leave early.
- Climb over Lookout on the way back, then land at **Base** to complete the mission. After a crash, **Retry** resumes from the last successful pickup and **New Run** starts from Base.

![Rotor Rescue helicopter returning to Base with six passengers.](docs/images/return-to-base.png)

| Boarding at Ridge | All six delivered |
| --- | --- |
| ![Two passengers wait beside the helicopter during boarding.](docs/images/boarding.png) | ![Mission complete after returning six passengers to Base.](docs/images/mission-complete.png) |

The menu and gameplay screenshots were captured in the X20RS simulator. Rotor Rescue 0.6.2 was also tested on a physical X20RS.

## Beat the score

Pickups earn 100, 200 and 300 points. Delivering everyone to Base earns another 300. The time bonus starts at 600 points and drops by four points per second and 150 per retry, down to zero. **Top Scores** keeps your five best completed flights on the radio.

Can you beat **1,310 points in 47.60 seconds with zero retries**?

![Physical FrSky X20RS showing the local record of 1,310 points in 47.60 seconds with zero retries.](docs/images/x20rs-high-score.jpg)
