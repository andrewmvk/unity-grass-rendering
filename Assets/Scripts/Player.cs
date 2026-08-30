using UnityEngine;
using UnityEngine.InputSystem;

public class Player : MonoBehaviour
{
    [SerializeField] private InputActionAsset InputActions;
    [SerializeField] private CharacterController playerCharacterController;
    [SerializeField] Transform playerCamera;

    private InputAction moveAction;
    private InputAction jumpAction;

    private Vector2 playerMoveAmount;

    private readonly float walkSpeed = 5.0f;
    private readonly float rotateDampening = 0.1f;
    private float turnSmoothingVelocity;
    private float verticalVelocity = 0f;
    private readonly float gravity = -9.8f;
    private readonly float jumpHeight = 5.0f;

    private void OnEnable()
    {
        InputActions.FindActionMap("Player").Enable();
    }

    private void OnDisable()
    {
        InputActions.FindActionMap("Player").Disable();
    }

    private void Awake()
    {
        moveAction = InputSystem.actions.FindAction("Move");
        jumpAction = InputSystem.actions.FindAction("Jump");
    }

    private void Update()
    {
        playerMoveAmount = moveAction.ReadValue<Vector2>();
        MoveAndRotate();
        Jump();
    }

    private void MoveAndRotate()
    {
        Vector3 playerDirection = new Vector3(playerMoveAmount.x, 0f, playerMoveAmount.y).normalized;
        Vector3 verticalMove = new Vector3(0f, verticalVelocity, 0f) * Time.deltaTime;

        if(playerDirection.magnitude >= 0.1f)
        {
            float targetAngle = Mathf.Atan2(playerDirection.x, playerDirection.z) * Mathf.Rad2Deg + playerCamera.eulerAngles.y;
            float smoothTargetAngle = Mathf.SmoothDampAngle(transform.eulerAngles.y, targetAngle, ref turnSmoothingVelocity, rotateDampening);

            transform.rotation = Quaternion.Euler(0f, smoothTargetAngle, 0f);
            
            Vector3 moveDirection = Quaternion.Euler(0f, targetAngle, 0f) * Vector3.forward;
            playerCharacterController.Move(Time.deltaTime * walkSpeed * moveDirection.normalized + verticalMove);
        }
        else
        {
            playerCharacterController.Move(verticalMove);
        }
    }

    private void Jump()
    {
        if(playerCharacterController.isGrounded)
        {
            verticalVelocity = -1f;
            if (jumpAction.WasPressedThisFrame())
            {
                verticalVelocity = jumpHeight;
            }
        }
        else
        {
            verticalVelocity += gravity * Time.deltaTime;
        }
    }
}

