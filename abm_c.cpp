#include <stdio.h>
#include <string.h>

#define MAX 3

typedef struct {
    float precio;
    int activo; // 1 = registrado, 0 = vacio
} Producto;


Producto inventario[MAX];


typedef enum {
    OPCION_ALTA = 1,
    OPCION_BAJA = 2,
    OPCION_MOSTRAR = 3,
    OPCION_SALIR = 4
} OpcionMenu;

void bienvenida(void) {
    printf("Bienvenido/a al sistema\n\n");
}

int autenticar(void) {
    char clave[10];
    int intentos = 0;

    while (intentos < 3) {
        printf("Ingrese clave (1234): ");
        scanf("%9s", clave);

        if (strcmp(clave, "1234") == 0) {
            printf("Acceso concedido.\n");
            return 1;
        }

        intentos++;
        printf("Clave incorrecta (%d/3 intentos).\n", intentos);
    }

    return 0;
}

void alta(int id, Producto p) {
    if (id < 0 || id >= MAX) {
        printf("Error: ID fuera de rango.\n");
        return;
    }
    inventario[id] = p;
    printf("Producto %d guardado con precio $%.2f.\n", id, p.precio);
}

void baja(int id) {
    if (id < 0 || id >= MAX) {
        printf("Error: ID fuera de rango.\n");
        return;
    }
    if (inventario[id].activo == 1) {
        inventario[id].activo = 0;
        printf("Producto %d eliminado.\n", id);
    } else {
        printf("El producto no existe.\n");
    }
}

void mostrar(void) {
    printf("\n--- INVENTARIO ---\n");
    for (int i = 0; i < MAX; i++) {
        if (inventario[i].activo == 1) {
            printf("ID %d : $%.2f\n", i, inventario[i].precio);
        }
    }
}

int main() {
   
    for (int i = 0; i < MAX; i++) {
        inventario[i].activo = 0;
    }

    bienvenida();

    if (!autenticar()) {
        printf("\nAcceso denegado.\n");
        return 0;
    }

    int opcion = 0;

    while (opcion != OPCION_SALIR) {
        printf("\n--- MENU ---\n");
        printf("1. Alta producto (ID 0 a %d)\n", MAX - 1);
        printf("2. Baja producto\n");
        printf("3. Mostrar inventario\n");
        printf("4. Salir\n");
        printf("Opcion: ");
        scanf("%d", &opcion);

        int id;
        Producto p_temp;

        switch ((OpcionMenu)opcion) {
            case OPCION_ALTA:
                printf("Ingrese ID (0-%d): ", MAX - 1);
                scanf("%d", &id);
                printf("Ingrese Precio: ");
                scanf("%f", &p_temp.precio);
                p_temp.activo = 1;

                alta(id, p_temp);
                break;

            case OPCION_BAJA:
                printf("Ingrese ID a eliminar (0-%d): ", MAX - 1);
                scanf("%d", &id);
                baja(id);
                break;

            case OPCION_MOSTRAR:
                mostrar();
                break;

            case OPCION_SALIR:
                printf("\nSaliendo del programa...\n");
                break;

            default:
                printf("\nOpcion invalida.\n");
                break;
        }
    }

    return 0;
}
